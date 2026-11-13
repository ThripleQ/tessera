// 渲染器：把 World 里的分组提交给 GL。
//
// 这里是窗口版和离屏版共用的唯一一份绘制代码 —— 换句话说，
// 你在窗口里看到的画面和 --out 出来的图，走的是同一串 GL 调用，
// 只有"把画面送到哪里"这一步不同。
//
// 封闭层。文件里没有一处回调、注册表或脚本钩子，这是故意的：
// 一段代码如果决定了"每帧提交多少东西"，它就不该被内容层碰到。
#pragma once
#include <chrono>
#include <cstdint>
#include <string>
#include <vector>

#include "gl.hpp"
#include "mathx.hpp"
#include "mesh.hpp"
#include "pack.hpp"
#include "world.hpp"

struct Camera {
    Vec3 eye;
    float yaw = 0.0f;    // 绕 Y 轴，0 朝 +Z
    float pitch = 0.0f;  // 正为抬头
};

namespace gfx {

inline GLuint compile(GLenum type, const char* src, std::string* err) {
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &src, nullptr);
    glCompileShader(s);
    GLint ok = 0;
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[2048];
        glGetShaderInfoLog(s, sizeof(log), nullptr, log);
        *err = log;
        glDeleteShader(s);
        return 0;
    }
    return s;
}

inline GLuint program(const char* vs_src, const char* fs_src, std::string* err) {
    GLuint vs = compile(GL_VERTEX_SHADER, vs_src, err);
    if (!vs) return 0;
    GLuint fs = compile(GL_FRAGMENT_SHADER, fs_src, err);
    if (!fs) { glDeleteShader(vs); return 0; }
    GLuint p = glCreateProgram();
    glAttachShader(p, vs);
    glAttachShader(p, fs);
    glLinkProgram(p);
    glDeleteShader(vs);
    glDeleteShader(fs);
    GLint linked = 0;
    glGetProgramiv(p, GL_LINK_STATUS, &linked);
    if (!linked) {
        char log[2048];
        glGetProgramInfoLog(p, sizeof(log), nullptr, log);
        *err = log;
        glDeleteProgram(p);
        return 0;
    }
    return p;
}

}  // namespace gfx

// ---------------------------------------------------------------- 着色器

static const char* VS_SCENE = R"GLSL(
#version 330 core
layout(location = 0) in vec3 aPos;
layout(location = 1) in vec3 aNrm;
layout(location = 2) in vec4 iPosScale;   // xyz = 世界位置, w = 统一缩放
layout(location = 3) in vec4 iTintYaw;    // rgb = 配色,   w = 朝向

uniform mat4 uViewProj;
uniform vec3 uCam;

out vec3 vN;
out vec3 vTint;
out vec3 vWorld;

void main() {
    float c = cos(iTintYaw.w), s = sin(iTintYaw.w);
    vec3 p = aPos * iPosScale.w;
    vec3 rp = vec3(p.x * c + p.z * s, p.y, -p.x * s + p.z * c);
    vec3 wp = rp + iPosScale.xyz;

    vWorld = wp;
    vN = normalize(vec3(aNrm.x * c + aNrm.z * s, aNrm.y, -aNrm.x * s + aNrm.z * c));
    vTint = iTintYaw.rgb;
    gl_Position = uViewProj * vec4(wp, 1.0);
}
)GLSL";

static const char* FS_SCENE = R"GLSL(
#version 330 core
in vec3 vN;
in vec3 vTint;
in vec3 vWorld;

out vec4 oColor;

uniform vec3 uLightDir;
uniform vec3 uFogColor;
uniform float uFogNear;
uniform float uFogFar;
uniform float uGridAmount;

// 光源数量是编译期上限，运行期由世界层限制在预算内。
// 内容想加多少发光怪都行，超过的部分在这里被静默丢掉 —— 这正是"预算封闭"。
uniform int uLightCount;
uniform vec4 uLightPos[8];
uniform float uLightInt[8];

uniform vec3 uCam;

void main() {
    vec3 n = normalize(vN);
    float ndl = max(dot(n, uLightDir), 0.0);
    float hemi = 0.5 + 0.5 * n.y;
    vec3 lit = vTint * (0.20 + 0.60 * ndl + 0.28 * hemi);

    for (int i = 0; i < 8; ++i) {
        if (i >= uLightCount) break;
        vec3 d = uLightPos[i].xyz - vWorld;
        float r = uLightPos[i].w;
        float att = clamp(1.0 - dot(d, d) / (r * r), 0.0, 1.0);
        lit += vTint * uLightInt[i] * att * att * 0.55;
    }

    // 雾必须在片元里按世界坐标算。用顶点插值出来的距离在超大三角形上
    // 是线性插的，会把整个地面一次压成雾色 —— 这个坑很典型。
    float d = distance(vWorld, uCam);
    float f = clamp((d - uFogNear) / max(uFogFar - uFogNear, 1e-3), 0.0, 1.0);

    if (uGridAmount > 0.0) {
        vec2 q = vWorld.xz * 0.5;
        vec2 gw = max(fwidth(q), vec2(1e-5));
        vec2 g = abs(fract(q - 0.5) - 0.5) / gw;
        float line = 1.0 - min(min(g.x, g.y), 1.0);
        // 网格必须跟着雾一起淡出。否则在掠射角上成千上万条线会糊成一条亮带，
        // 看起来像地平线在发光 —— 那是走样，不是美术效果。
        lit += vec3(0.075) * line * uGridAmount * (1.0 - f) * (1.0 - f);
    }

    // 软压缩。没有这一步，密集场景里 8 盏灯叠在同一批物体上会直接爆白 ——
    // 这不是美术问题，是"光能量必须可积"的物理约束。
    lit = vec3(1.0) - exp(-lit * 2.0);

    oColor = vec4(mix(lit, uFogColor, f * f), 1.0);
}
)GLSL";

// 准星。用满屏三角形 + 片元里算距离，零顶点数据、一个 draw call。
static const char* VS_OVERLAY = R"GLSL(
#version 330 core
void main() {
    vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
)GLSL";

static const char* FS_CROSSHAIR = R"GLSL(
#version 330 core
out vec4 oColor;
uniform vec2 uRes;
uniform float uAspect;

void main() {
    vec2 p = (gl_FragCoord.xy / uRes) * 2.0 - 1.0;
    p.x *= uAspect;
    float gap = 0.006;      // 中心留空，不遮住准心瞄的东西
    float len = 0.020;
    float arm = 0.0016;
    float hx = (abs(p.y) < arm) ? step(gap, abs(p.x)) * step(abs(p.x), gap + len) : 0.0;
    float vy = (abs(p.x) < arm) ? step(gap, abs(p.y)) * step(abs(p.y), gap + len) : 0.0;
    float m = max(hx, vy);
    if (m < 0.5) discard;
    oColor = vec4(0.92, 0.93, 0.95, 1.0);
}
)GLSL";

// 接触阴影。给每个可见物体脚下一枚暗斑，用乘算混合（dst *= src），
// 所以不需要排序、不需要模板、也不会盖住别的东西。
// 低模场景里它的作用被严重低估：有没有这一层，是"物体浮在地上"和
// "物体站在地上"的差别。
static const char* VS_SHADOW = R"GLSL(
#version 330 core
layout(location = 0) in vec3 aPos;
layout(location = 2) in vec4 iPosScale;
layout(location = 3) in vec4 iTintYaw;

uniform mat4 uViewProj;

out vec2 vLocal;
out float vFade;

void main() {
    float c = cos(iTintYaw.w), s = sin(iTintYaw.w);
    vec3 p = aPos * (iPosScale.w * 0.85);
    vec3 rp = vec3(p.x * c + p.z * s, p.y, -p.x * s + p.z * c);
    vec3 wp = rp + iPosScale.xyz;
    wp.y = 0.02;                       // 贴地，靠多边形偏移之外的手动抬升解决 z-fighting
    vLocal = aPos.xz;                  // -1..1
    vFade = clamp(iPosScale.w, 0.6, 2.0);
    gl_Position = uViewProj * vec4(wp, 1.0);
}
)GLSL";

static const char* FS_SHADOW = R"GLSL(
#version 330 core
in vec2 vLocal;
in float vFade;
out vec4 oColor;

void main() {
    float r = length(vLocal);
    float a = smoothstep(1.0, 0.15, r);
    // 乘算：输出白色 = 不变，输出灰色 = 压暗
    oColor = vec4(vec3(1.0 - 0.55 * a / vFade), 1.0);
}
)GLSL";


// 抬头低头时地平线要跟着动，所以用 tan(pitch) 把渐变整体平移 ——
// 不做真天空球，是因为这一层只要"远处有空气"，多一个球体不值得。
static const char* FS_SKY = R"GLSL(
#version 330 core
out vec4 oColor;
uniform vec2 uRes;
uniform float uPitch;      // 弧度
uniform vec3 uZenith;
uniform vec3 uHorizon;

void main() {
    vec2 p = (gl_FragCoord.xy / uRes) * 2.0 - 1.0;
    float y = p.y + tan(uPitch) * 1.428f;   // 1.428 ≈ 1/tan(fov_half)
    float t = clamp(y * 0.5 + 0.5, 0.0, 1.0);
    vec3 c = mix(uHorizon, uZenith, pow(t, 0.75));
    // 地平线附近压一点暗，避免"上下两块颜色"的接缝感
    c *= 1.0 - 0.18 * smoothstep(0.30, 0.02, abs(y));
    oColor = vec4(c, 1.0);
}
)GLSL";

// ---------------------------------------------------------------- 渲染器

struct GpuMesh {
    GLuint vao = 0, vbo = 0;
    GLsizei verts = 0;
    uint32_t tris = 0;
};

class Renderer {
  public:
    bool init(const ContentPack& pack, std::string* err) {
        prog_ = gfx::program(VS_SCENE, FS_SCENE, err);
        if (!prog_) return false;
        prog_ui_ = gfx::program(VS_OVERLAY, FS_CROSSHAIR, err);
        if (!prog_ui_) return false;
        prog_sky_ = gfx::program(VS_OVERLAY, FS_SKY, err);
        if (!prog_sky_) return false;
        prog_shadow_ = gfx::program(VS_SHADOW, FS_SHADOW, err);
        if (!prog_shadow_) return false;

        gpu_.reserve(pack.meshes.size());
        for (const ProtoMesh& m : pack.meshes) {
            MeshData d = build_mesh(m.name.c_str());
            if (d.tris != m.tris) {
                std::fprintf(stderr, "警告: 网格 %s 实际 %u 个三角形，registry 里写的是 %u\n",
                             m.name.c_str(), d.tris, m.tris);
            }
            gpu_.push_back(upload(d));
        }

        // 地面：一个两三角的方块，靠实例的 scale 放满整个视野。
        MeshData g;
        Vertex v0{-1, 0, 1, 0, 1, 0}, v1{1, 0, 1, 0, 1, 0};
        Vertex v2{1, 0, -1, 0, 1, 0}, v3{-1, 0, -1, 0, 1, 0};
        g.verts = {v0, v1, v2, v0, v2, v3};
        g.tris = 2;
        ground_ = upload(g);

        // 阴影用的方块：和地面同一套顶点，只是渲染时贴地 + 乘算压暗。
        MeshData sh;
        Vertex s0{-1, 0, -1, 0, 1, 0}, s1{1, 0, -1, 0, 1, 0};
        Vertex s2{1, 0, 1, 0, 1, 0}, s3{-1, 0, 1, 0, 1, 0};
        sh.verts = {s0, s1, s2, s0, s2, s3};
        sh.tris = 2;
        shadow_ = upload(sh);

        glGenVertexArrays(1, &empty_vao_);

        // 状态只设一次。这些开关属于渲染器，不属于内容。
        glEnable(GL_DEPTH_TEST);
        glDepthFunc(GL_LESS);
        glEnable(GL_CULL_FACE);
        glCullFace(GL_BACK);
        glFrontFace(GL_CCW);
        glClearColor(0.145f, 0.140f, 0.150f, 1.0f);
        return true;
    }

    // 一帧。stats 由 world.step() 提前算好，这里只负责提交。
    void draw(const World& world, const Camera& cam, int w, int h, bool instancing,
              bool crosshair) {
        const float aspect = static_cast<float>(w) / static_cast<float>(h);
        Vec3 fwd{std::sin(cam.yaw) * std::cos(cam.pitch), std::sin(cam.pitch),
                 std::cos(cam.yaw) * std::cos(cam.pitch)};
        Mat4 view = mat_look_at(cam.eye, cam.eye + fwd, v3(0, 1, 0));
        Mat4 proj = mat_perspective(FOV_HALF * 2.0f, aspect, 0.1f, 400.0f);
        Mat4 vp = mat_mul(proj, view);

        glUseProgram(prog_);
        glUniformMatrix4fv(loc_vp_, 1, GL_FALSE, vp.m);
        glUniform3f(loc_cam_, cam.eye.x, cam.eye.y, cam.eye.z);

        const std::vector<LightOut>& lights = world.lights();
        int lc = static_cast<int>(lights.size());
        if (lc > 8) lc = 8;
        float lp[32] = {0};
        float li[8] = {0};
        for (int i = 0; i < lc; ++i) {
            lp[i * 4 + 0] = lights[i].x;
            lp[i * 4 + 1] = lights[i].y;
            lp[i * 4 + 2] = lights[i].z;
            lp[i * 4 + 3] = lights[i].r;
            li[i] = lights[i].intensity;
        }
        glUniform1i(loc_lcount_, lc);
        glUniform4fv(loc_lpos_, 8, lp);
        glUniform1fv(loc_lint_, 8, li);

        glViewport(0, 0, w, h);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

        // 天空：满屏一个三角形，不写深度、不测深度，纯背景。
        glUseProgram(prog_sky_);
        glUniform2f(loc_sky_res_, static_cast<float>(w), static_cast<float>(h));
        glUniform1f(loc_sky_pitch_, cam.pitch);
        glUniform3f(loc_sky_zen_, 0.030f, 0.034f, 0.052f);
        glUniform3f(loc_sky_hor_, 0.145f, 0.140f, 0.150f);
        glDisable(GL_DEPTH_TEST);
        glBindVertexArray(empty_vao_);
        glDrawArrays(GL_TRIANGLES, 0, 3);
        glEnable(GL_DEPTH_TEST);
        glBindVertexArray(0);
        glUseProgram(prog_);

        // 地面：跟着相机走 + 只覆盖雾的射程。
        // 如果按世界尺寸放大，顶点坐标会到几千，虽然裁剪能处理，但那是浪费；
        // 而单面地面本来就没有背面，不该参与剔除。
        glUniform1f(loc_grid_, 1.0f);
        glDisable(GL_CULL_FACE);
        {
            glBindVertexArray(ground_.vao);
            if (ground_vbo_ == 0) glGenBuffers(1, &ground_vbo_);
            float inst[8] = {cam.eye.x, 0.0f, cam.eye.z, 170.0f, 0.20f, 0.195f, 0.185f, 0.0f};
            glBindBuffer(GL_ARRAY_BUFFER, ground_vbo_);
            glBufferData(GL_ARRAY_BUFFER, sizeof(inst), inst, GL_STREAM_DRAW);
            bind_instance_attribs();
            glDrawArraysInstanced(GL_TRIANGLES, 0, ground_.verts, 1);
        }
        glEnable(GL_CULL_FACE);

        glUniform1f(loc_grid_, 0.0f);
        const std::vector<Group>& groups = world.groups();
        if (vbo_.size() < groups.size()) {
            vbo_.resize(groups.size(), 0);
            cap_.resize(groups.size(), 0);
        }

        // 1) 先把每组的实例数据传上去，后面阴影和内容各用一次，
        //    但数据只传一遍。省下的是带宽，对核显是实打实的。
        for (size_t gi = 0; gi < groups.size(); ++gi) {
            const Group& g = groups[gi];
            if (vbo_[gi] == 0) glGenBuffers(1, &vbo_[gi]);
            const size_t bytes = g.inst.size() * sizeof(float);
            glBindBuffer(GL_ARRAY_BUFFER, vbo_[gi]);
            if (bytes > cap_[gi]) {
                glBufferData(GL_ARRAY_BUFFER, static_cast<GLsizeiptr>(bytes), g.inst.data(),
                             GL_STREAM_DRAW);
                cap_[gi] = bytes;
            } else {
                glBufferSubData(GL_ARRAY_BUFFER, 0, static_cast<GLsizeiptr>(bytes), g.inst.data());
            }
        }

        // 2) 接触阴影：一次 draw call 一批，乘算混合，不排序。
        if (shadows_) {
            glUseProgram(prog_shadow_);
            glUniformMatrix4fv(loc_shadow_vp_, 1, GL_FALSE, vp.m);
            glEnable(GL_BLEND);
            glBlendFunc(GL_DST_COLOR, GL_ZERO);
            glDepthMask(GL_FALSE);
            glDisable(GL_CULL_FACE);
            for (size_t gi = 0; gi < groups.size(); ++gi) {
                const Group& g = groups[gi];
                glBindVertexArray(shadow_.vao);
                glBindBuffer(GL_ARRAY_BUFFER, vbo_[gi]);
                bind_instance_attribs();
                glDrawArraysInstanced(GL_TRIANGLES, 0, shadow_.verts,
                                      static_cast<GLsizei>(g.inst.size() / 8));
            }
            glDepthMask(GL_TRUE);
            glDisable(GL_BLEND);
            glEnable(GL_CULL_FACE);
            glUseProgram(prog_);
        }

        // 3) 内容本体。
        if (instancing) {
            for (size_t gi = 0; gi < groups.size(); ++gi) {
                const Group& g = groups[gi];
                glBindVertexArray(gpu_[g.mesh].vao);
                glBindBuffer(GL_ARRAY_BUFFER, vbo_[gi]);
                bind_instance_attribs();
                glDrawArraysInstanced(GL_TRIANGLES, 0, gpu_[g.mesh].verts,
                                      static_cast<GLsizei>(g.inst.size() / 8));
            }
        } else {
            // 关掉合批：一物一次提交。数字一样，实际调用次数差两个数量级。
            if (vbo_.empty()) { vbo_.push_back(0); cap_.push_back(0); }
            if (vbo_[0] == 0 || cap_[0] < 32) {
                if (vbo_[0] == 0) glGenBuffers(1, &vbo_[0]);
                glBindBuffer(GL_ARRAY_BUFFER, vbo_[0]);
                glBufferData(GL_ARRAY_BUFFER, 32, nullptr, GL_STREAM_DRAW);
                cap_[0] = 32;
            }
            for (const Group& g : groups) {
                for (size_t k = 0; k + 8 <= g.inst.size(); k += 8) {
                    glBindVertexArray(gpu_[g.mesh].vao);
                    glBindBuffer(GL_ARRAY_BUFFER, vbo_[0]);
                    glBufferSubData(GL_ARRAY_BUFFER, 0, 32, &g.inst[k]);
                    bind_instance_attribs();
                    glDrawArraysInstanced(GL_TRIANGLES, 0, gpu_[g.mesh].verts, 1);
                }
            }
        }
        glBindVertexArray(0);

        if (crosshair) {
            glUseProgram(prog_ui_);
            glUniform2f(loc_res_, static_cast<float>(w), static_cast<float>(h));
            glUniform1f(loc_aspect_, aspect);
            glDisable(GL_DEPTH_TEST);
            glBindVertexArray(empty_vao_);
            glDrawArrays(GL_TRIANGLES, 0, 3);
            glEnable(GL_DEPTH_TEST);
            glBindVertexArray(0);
        }
    }

    void set_fog(float near_d, float far_d) {
        glUseProgram(prog_);
        glUniform1f(glGetUniformLocation(prog_, "uFogNear"), near_d);
        glUniform1f(glGetUniformLocation(prog_, "uFogFar"), far_d);
    }

    // 一次性的常量 uniform，init 之后调一次。
    void uniform_consts() {
        glUseProgram(prog_);
        Vec3 ld = normalize(v3(-0.45f, 0.82f, 0.36f));
        glUniform3f(glGetUniformLocation(prog_, "uLightDir"), ld.x, ld.y, ld.z);
        glUniform3f(glGetUniformLocation(prog_, "uFogColor"), 0.145f, 0.140f, 0.150f);
        glUniform1f(glGetUniformLocation(prog_, "uFogNear"), 26.0f);
        glUniform1f(glGetUniformLocation(prog_, "uFogFar"), 92.0f);
        loc_vp_ = glGetUniformLocation(prog_, "uViewProj");
        loc_cam_ = glGetUniformLocation(prog_, "uCam");
        loc_grid_ = glGetUniformLocation(prog_, "uGridAmount");
        loc_lcount_ = glGetUniformLocation(prog_, "uLightCount");
        loc_lpos_ = glGetUniformLocation(prog_, "uLightPos");
        loc_lint_ = glGetUniformLocation(prog_, "uLightInt");
        loc_res_ = glGetUniformLocation(prog_ui_, "uRes");
        loc_aspect_ = glGetUniformLocation(prog_ui_, "uAspect");
        loc_sky_res_ = glGetUniformLocation(prog_sky_, "uRes");
        loc_sky_pitch_ = glGetUniformLocation(prog_sky_, "uPitch");
        loc_sky_zen_ = glGetUniformLocation(prog_sky_, "uZenith");
        loc_sky_hor_ = glGetUniformLocation(prog_sky_, "uHorizon");
        loc_shadow_vp_ = glGetUniformLocation(prog_shadow_, "uViewProj");
    }

    void set_shadows(bool on) { shadows_ = on; }

  private:
    static GpuMesh upload(const MeshData& m) {
        GpuMesh g;
        glGenVertexArrays(1, &g.vao);
        glBindVertexArray(g.vao);
        glGenBuffers(1, &g.vbo);
        glBindBuffer(GL_ARRAY_BUFFER, g.vbo);
        glBufferData(GL_ARRAY_BUFFER,
                     static_cast<GLsizeiptr>(m.verts.size() * sizeof(Vertex)),
                     m.verts.data(), GL_STATIC_DRAW);
        glEnableVertexAttribArray(0);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, sizeof(Vertex),
                              reinterpret_cast<void*>(0));
        glEnableVertexAttribArray(1);
        glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, sizeof(Vertex),
                              reinterpret_cast<void*>(offsetof(Vertex, nx)));
        g.verts = static_cast<GLsizei>(m.verts.size());
        g.tris = m.tris;
        glBindVertexArray(0);
        return g;
    }

    static void bind_instance_attribs() {
        glEnableVertexAttribArray(2);
        glVertexAttribPointer(2, 4, GL_FLOAT, GL_FALSE, 32, reinterpret_cast<void*>(0));
        glVertexAttribDivisor(2, 1);
        glEnableVertexAttribArray(3);
        glVertexAttribPointer(3, 4, GL_FLOAT, GL_FALSE, 32, reinterpret_cast<void*>(16));
        glVertexAttribDivisor(3, 1);
    }

    GLuint prog_ = 0, prog_ui_ = 0, prog_sky_ = 0, prog_shadow_ = 0, empty_vao_ = 0;
    GLuint ground_vbo_ = 0;
    bool shadows_ = true;
    GpuMesh ground_, shadow_;
    std::vector<GpuMesh> gpu_;
    std::vector<GLuint> vbo_;
    std::vector<size_t> cap_;
    GLint loc_vp_ = -1, loc_cam_ = -1, loc_grid_ = -1, loc_lcount_ = -1, loc_lpos_ = -1,
          loc_lint_ = -1, loc_res_ = -1, loc_aspect_ = -1;
    GLint loc_sky_res_ = -1, loc_sky_pitch_ = -1, loc_sky_zen_ = -1, loc_sky_hor_ = -1;
    GLint loc_shadow_vp_ = -1;
};
