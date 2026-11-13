// 离屏渲染器：用 EGL 开一个不依赖显示器的 GL 上下文，渲染后落盘成图片。
//
// 两个用途：
//   1. 自检 —— 在没有显示器的环境里也能出真图（走的是和窗口版同一份 renderer.hpp）。
//   2. --replay —— 用同一套玩家控制器跑一段脚本化走位并逐帧导出，
//      这样"移动中的世界"也能在没有窗口的地方被看见和验证。
//
// 用法：
//   ./shot --pack ../build/content.pack.bin --n 30000 --t 3.0 --out shot.ppm
//   ./shot --replay build/frames --frames 120      # 逐帧导出，之后交给 ffmpeg

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include <EGL/egl.h>
#include <EGL/eglext.h>

#include "gl.hpp"
#include "mathx.hpp"
#include "mesh.hpp"
#include "pack.hpp"
#include "player.hpp"
#include "renderer.hpp"
#include "world.hpp"

// ---------------------------------------------------------------- EGL

struct GlCtx {
    EGLDisplay dpy = EGL_NO_DISPLAY;
    EGLContext ctx = EGL_NO_CONTEXT;
    EGLSurface surf = EGL_NO_SURFACE;
    int w = 0, h = 0;
};

static bool egl_up(GlCtx& out, int w, int h, std::string* err) {
    auto getPlatformDisplay = reinterpret_cast<PFNEGLGETPLATFORMDISPLAYEXTPROC>(
        eglGetProcAddress("eglGetPlatformDisplayEXT"));
    if (!getPlatformDisplay) { *err = "缺 eglGetPlatformDisplayEXT"; return false; }

    out.dpy = getPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, nullptr);
    EGLint major = 0, minor = 0;
    if (out.dpy == EGL_NO_DISPLAY || !eglInitialize(out.dpy, &major, &minor)) {
        *err = "eglInitialize 失败";
        return false;
    }
    if (!eglBindAPI(EGL_OPENGL_API)) { *err = "绑不上 OpenGL"; return false; }

    const EGLint cfg_attr[] = {
        EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_DEPTH_SIZE, 24,
        EGL_NONE
    };
    EGLConfig cfg; EGLint n = 0;
    if (!eglChooseConfig(out.dpy, cfg_attr, &cfg, 1, &n) || n < 1) {
        *err = "eglChooseConfig 失败";
        return false;
    }

    const EGLint ctx_attr[] = {
        EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 3,
        EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
        EGL_NONE
    };
    out.ctx = eglCreateContext(out.dpy, cfg, EGL_NO_CONTEXT, ctx_attr);
    if (out.ctx == EGL_NO_CONTEXT) { *err = "eglCreateContext 失败"; return false; }

    const EGLint pb_attr[] = {EGL_WIDTH, w, EGL_HEIGHT, h, EGL_NONE};
    out.surf = eglCreatePbufferSurface(out.dpy, cfg, pb_attr);
    if (out.surf == EGL_NO_SURFACE) { *err = "pbuffer 失败"; return false; }
    if (!eglMakeCurrent(out.dpy, out.surf, out.surf, out.ctx)) {
        *err = "eglMakeCurrent 失败";
        return false;
    }
    out.w = w; out.h = h;
    return true;
}

// ---------------------------------------------------------------- 输出

static bool write_ppm(const char* path, int w, int h, const std::vector<uint8_t>& rgba) {
    FILE* f = std::fopen(path, "wb");
    if (!f) return false;
    std::fprintf(f, "P6\n%d %d\n255\n", w, h);
    std::vector<uint8_t> row(static_cast<size_t>(w) * 3);
    for (int y = h - 1; y >= 0; --y) {  // GL 原点在左下，图片原点在左上
        const uint8_t* src = rgba.data() + static_cast<size_t>(y) * w * 4;
        for (int x = 0; x < w; ++x) {
            row[x * 3 + 0] = src[x * 4 + 0];
            row[x * 3 + 1] = src[x * 4 + 1];
            row[x * 3 + 2] = src[x * 4 + 2];
        }
        std::fwrite(row.data(), 1, row.size(), f);
    }
    std::fclose(f);
    return true;
}

// ---------------------------------------------------------------- main

struct Args {
    const char* pack = "build/content.pack.bin";
    const char* out = "build/shot.ppm";
    const char* replay = nullptr;
    int w = 1280, h = 720;
    int n = 30000;
    int frames = 60;
    int lights = 8;
    float density = 0.02f;
    float t_override = -1.0f;
    float at_x = 0.0f, at_z = 0.0f, at_yaw = 0.0f;
    bool at_set = false;
    float fps = 30.0f;
    bool instancing = true;
    bool json = false;
};

int main(int argc, char** argv) {
    Args a;
    for (int i = 1; i < argc; ++i) {
        std::string k = argv[i];
        auto next = [&]() -> const char* { return (i + 1 < argc) ? argv[++i] : ""; };
        if (k == "--pack") a.pack = next();
        else if (k == "--out") a.out = next();
        else if (k == "--replay") a.replay = next();
        else if (k == "--w") a.w = std::atoi(next());
        else if (k == "--h") a.h = std::atoi(next());
        else if (k == "--n") a.n = std::atoi(next());
        else if (k == "--frames") a.frames = std::atoi(next());
        else if (k == "--lights") a.lights = std::atoi(next());
        else if (k == "--density") a.density = static_cast<float>(std::atof(next()));
        else if (k == "--t") a.t_override = static_cast<float>(std::atof(next()));
        else if (k == "--at") {
            // --at "x,z,yaw"：钉死相机。对比密度时必须这么干 ——
            // 自动巡航的相机会跑到世界角落朝外看，两个场景就不可比了。
            const char* s = next();
            if (std::sscanf(s, "%f,%f,%f", &a.at_x, &a.at_z, &a.at_yaw) == 3) a.at_set = true;
        }
        else if (k == "--fps") a.fps = static_cast<float>(std::atof(next()));
        else if (k == "--no-instancing") a.instancing = false;
        else if (k == "--json") a.json = true;
        else if (k == "-h" || k == "--help") {
            std::printf("用法: shot [--pack FILE] [--n 数量] [--out 图片] [--w 宽] [--h 高]\n"
                        "            [--frames 帧数] [--t 时刻] [--replay 目录] [--fps 帧率]\n"
                        "            [--lights 预算] [--no-instancing] [--json]\n");
            return 0;
        }
    }

    ContentPack pack;
    std::string err;
    if (!packio::load(a.pack, pack, &err)) {
        std::fprintf(stderr, "内容包读取失败: %s\n", err.c_str());
        return 1;
    }

    GlCtx gl;
    if (!egl_up(gl, a.w, a.h, &err)) {
        std::fprintf(stderr, "GL 上下文创建失败: %s\n", err.c_str());
        return 1;
    }
    std::printf("GL  %s | %s\n", glGetString(GL_VERSION), glGetString(GL_RENDERER));

    Renderer r;
    if (!r.init(pack, &err)) {
        std::fprintf(stderr, "渲染器初始化失败:\n%s\n", err.c_str());
        return 1;
    }
    r.uniform_consts();

    World world(pack, 120.0f, 30.0f, a.lights, 7, a.density);
    world.populate(static_cast<uint32_t>(a.n));

    Player player;
    player.reset(world.extent() * 0.5f, world.extent() * 0.5f, 0.0f);

    Stats st;
    double render_ms = 0.0;
    std::vector<uint8_t> pixels(static_cast<size_t>(a.w) * a.h * 4);
    const float dt = 1.0f / (a.fps > 1.0f ? a.fps : 30.0f);

    for (int frame = 0; frame < a.frames; ++frame) {
        Camera cam;
        if (a.replay) {
            // 脚本化走位：一开始直走，逐渐右转，后半段加速。
            // 用的是和窗口版同一个 Player，所以这段动画就是"按住 W 转身疾走"。
            const float t = static_cast<float>(frame) * dt;
            Input in;
            in.move_z = 1.0f;
            in.sprint = t > 2.5f;
            in.look_dx = 0.42f * std::sin(t * 0.55f) * dt;
            in.look_dy = 0.10f * std::sin(t * 0.31f) * dt;
            player.update(in, dt, world.extent());
            cam = player.camera();
        } else if (a.at_set) {
            cam = Camera{v3(a.at_x, 2.9f, a.at_z), a.at_yaw, -0.197f};
            world.set_camera(a.at_x, a.at_z, a.at_yaw);
        } else {
            world.move_camera(a.t_override >= 0.0f ? a.t_override
                                                  : static_cast<float>(frame) / 30.0f);
            cam = Camera{v3(world.cam_x(), 2.9f, world.cam_z()), world.cam_yaw(), -0.197f};
        }

        world.set_camera(cam.eye.x, cam.eye.z, cam.yaw);
        st = world.step(a.instancing);

        auto t0 = std::chrono::steady_clock::now();
        r.draw(world, cam, a.w, a.h, a.instancing, false);
        glFinish();
        auto t1 = std::chrono::steady_clock::now();
        render_ms += std::chrono::duration<double, std::milli>(t1 - t0).count();

        if (a.replay) {
            char path[512];
            std::snprintf(path, sizeof(path), "%s_%04d.ppm", a.replay, frame);
            glReadPixels(0, 0, a.w, a.h, GL_RGBA, GL_UNSIGNED_BYTE, pixels.data());
            write_ppm(path, a.w, a.h, pixels);
        }
    }

    if (a.replay) {
        std::printf("导出 %d 帧（%.0f fps，%.1f 秒）-> %s_%%04d.ppm\n", a.frames, a.fps,
                    a.frames / a.fps, a.replay);
        std::printf("平均 %.2f ms/帧（含 glFinish，%dx%d）\n",
                    render_ms / (a.frames > 0 ? a.frames : 1), a.w, a.h);
        std::printf("最后一帧：可见 %u / %u draw / %llu 三角形 / 灯 %u(+%u)\n", st.visible,
                    st.draw_calls, static_cast<unsigned long long>(st.triangles), st.lights,
                    st.lights_capped);
        return 0;
    }

    glReadPixels(0, 0, a.w, a.h, GL_RGBA, GL_UNSIGNED_BYTE, pixels.data());
    if (!write_ppm(a.out, a.w, a.h, pixels)) {
        std::fprintf(stderr, "写图片失败: %s\n", a.out);
        return 1;
    }

    render_ms /= (a.frames > 0 ? a.frames : 1);

    if (a.json) {
        std::printf("{\n");
        std::printf("  \"n\": %d,\n", a.n);
        std::printf("  \"resident_chunks\": %u,\n", st.resident_chunks);
        std::printf("  \"resident_entities\": %u,\n", st.resident_entities);
        std::printf("  \"active\": %u,\n", st.active);
        std::printf("  \"visible\": %u,\n", st.visible);
        std::printf("  \"draw_calls\": %u,\n", st.draw_calls);
        std::printf("  \"triangles\": %llu,\n", static_cast<unsigned long long>(st.triangles));
        std::printf("  \"lights\": %u,\n", st.lights);
        std::printf("  \"lights_capped\": %u,\n", st.lights_capped);
        std::printf("  \"render_ms\": %.3f,\n", render_ms);
        std::printf("  \"instancing\": %s\n", a.instancing ? "true" : "false");
        std::printf("}\n");
        return 0;
    }

    std::printf("\n内容 %d 条  ->  驻留区块 %u / 驻留实体 %u / 激活 %u / 可见 %u\n", a.n,
                st.resident_chunks, st.resident_entities, st.active, st.visible);
    std::printf("提交 %u 次 draw call, %llu 个三角形, %u 盏动态光（收走 %u 盏）\n", st.draw_calls,
                static_cast<unsigned long long>(st.triangles), st.lights, st.lights_capped);
    std::printf("渲染 %d 帧，平均 %.2f ms/帧（含 glFinish，软件光栅 %dx%d）\n", a.frames, render_ms,
                a.w, a.h);
    std::printf("图片 -> %s\n", a.out);
    return 0;
}
