shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, specular_disabled;

// 卡通着色：把连续的光照压成两级色阶，再加一层边缘光。
//
// 为什么不用 StandardMaterial3D 调参数：卡通的关键不是"看起来平"，
// 而是**明暗边界是一条硬线**。PBR 的 N·L 连续渐变永远出不来这条线，
// 而这条线正是"动漫感"的主要来源——比多边形数和贴图精度重要得多。
//
// 配色来源：MultiMesh 的 instance color 走 COLOR 顶点属性，和 albedo 相乘。
// 所以同一个材质就能画整个世界，换色不增加 draw call。

uniform vec4 base_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);

// 明暗分界的阈值。越大暗部越多。
uniform float shade_threshold : hint_range(0.0, 1.0) = 0.34;
// 分界的柔度。0 = 硬边（纯卡通），稍大一点能避免锯齿闪动。
uniform float shade_softness : hint_range(0.0, 0.5) = 0.02;
// 暗部染色。偏冷的蓝紫是最常见的选择，纯黑会脏。
uniform vec4 shade_tint : source_color = vec4(0.66, 0.71, 0.90, 1.0);
// 暗部保留多少基础亮度。这个值不能低：垂直面（人的正面、箱子的侧面）
// 的 N·L 天然就只有 0.3~0.6，压太狠整个世界的立面都会变成一团黑。
uniform float shade_floor : hint_range(0.0, 1.0) = 0.40;

uniform float rim_power : hint_range(0.5, 8.0) = 3.2;
uniform float rim_strength : hint_range(0.0, 2.0) = 0.5;
uniform vec4 rim_tint : source_color = vec4(0.86, 0.93, 1.0, 1.0);

// 最终亮度标定。这不是物理量，是**实测校准值**：
// Compatibility 渲染器给进 light() 的 LIGHT_COLOR 与 Forward+ 不是同一个量级，
// 光靠除以 PI 无法让两种渲染器一致。所以留一个显式的旋钮，
// 换渲染器时只改这一个数字，不用重写光照模型。
uniform float light_gain : hint_range(0.0, 2.0) = 0.40;


void fragment() {
	vec3 tint = base_color.rgb * COLOR.rgb;
	// COLOR 在非 MultiMesh 的网格上可能是 (0,0,0)（顶点色未赋值）。
	// 不做这个兜底，凡是没有顶点色的独立网格都会变成一块黑。
	if (length(COLOR.rgb) < 0.001) {
		tint = base_color.rgb;
	}
	ALBEDO = tint;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}


void light() {
	vec3 n = normalize(NORMAL);
	vec3 v = normalize(VIEW);
	float ndl = dot(n, normalize(LIGHT));

	// 两级量化：亮面 1.0，暗面 shade_floor。中间只有极窄的过渡带。
	float lit = smoothstep(shade_threshold - shade_softness,
			shade_threshold + shade_softness, ndl);
	float band = mix(shade_floor, 1.0, lit);
	vec3 band_color = mix(shade_tint.rgb, vec3(1.0), lit);

	// 边缘光：轮廓处提亮，让角色的剪影从背景里跳出来。
	float rim = pow(1.0 - clamp(dot(n, v), 0.0, 1.0), rim_power);

	vec3 light_in = LIGHT_COLOR.rgb * ATTENUATION;
	vec3 diffuse = light_in * band_color * band / PI;
	DIFFUSE_LIGHT += diffuse * light_gain;
	DIFFUSE_LIGHT += light_in * rim_tint.rgb * rim * rim_strength * lit / PI * light_gain;
}
