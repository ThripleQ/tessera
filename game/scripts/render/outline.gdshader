shader_type spatial;
render_mode unshaded, cull_front, depth_draw_opaque;

// 描边：反向外扩（inverted hull）。
//
// 做法是把模型沿法线吹大一圈、只画背面，于是每根轮廓外沿都会露出一条边。
// 这是 Compatibility（OpenGL 3.3）下唯一可行的描边方案——没有几何着色器，
// 也不能靠后处理深度边缘，因为 Compatibility 不提供免费的深度纹理。
//
// 代价：每个网格多一次提交。所以描边是**可选的能力**，不是默认全局开启。
//
// 宽度要跟着距离走：固定宽度在远处会糊成一片黑边，走近又会细得看不见。
// 按视图空间距离放大，屏幕上的像素宽度才大致恒定。

uniform vec4 outline_color : source_color = vec4(0.07, 0.06, 0.10, 1.0);
uniform float width : hint_range(0.0, 0.1) = 0.028;
uniform float distance_scale : hint_range(0.0, 1.0) = 0.20;
uniform float min_scale : hint_range(0.0, 3.0) = 0.85;
uniform float max_scale : hint_range(0.0, 6.0) = 2.6;


void vertex() {
	float view_dist = length((MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz);
	float grow = clamp(view_dist * distance_scale, min_scale, max_scale);
	VERTEX += NORMAL * width * grow;
}


void fragment() {
	ALBEDO = outline_color.rgb;
}
