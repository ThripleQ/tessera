// 窗口版：真正的游戏循环。
//
// 渲染核心和离屏版共用 renderer.hpp；这里只多了三件事：
// 一个窗口、一套输入、一个每帧推进的玩家。
//
// 用法：
//   ./game --pack ../build/content.pack.bin --n 30000
//   ./game --frames 90 --shot build/win.ppm     # 开窗跑 90 帧，截一张图，退出
//
// 键位：
//   WASD / 方向键   移动      Shift  疾走
//   鼠标             转向      Esc    退出
//   B                开关合批（看 draw call 从 3 跳到 168）
//   V                开关垂直同步
//   R                回到世界中心

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "player.hpp"
#include "renderer.hpp"
#include "window.hpp"

static double now_s() {
    using namespace std::chrono;
    return duration<double>(steady_clock::now().time_since_epoch()).count();
}

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

struct Args {
    const char* pack = "build/content.pack.bin";
    const char* shot = nullptr;
    int w = 1280, h = 720;
    int n = 30000;
    int lights = 8;
    int frames = 0;  // >0 时跑完就退出（截图 / 自检用）
    int shot_at = -1;
    float density = 0.06f;  // 比离屏版密：窗口版是给人看的，得有点像样的世界
    float sens = 0.0022f;
    bool crosshair = true;
    bool vsync = true;
};

int main(int argc, char** argv) {
    Args a;
    for (int i = 1; i < argc; ++i) {
        std::string k = argv[i];
        auto next = [&]() -> const char* { return (i + 1 < argc) ? argv[++i] : ""; };
        if (k == "--pack") a.pack = next();
        else if (k == "--shot") a.shot = next();
        else if (k == "--w") a.w = std::atoi(next());
        else if (k == "--h") a.h = std::atoi(next());
        else if (k == "--n") a.n = std::atoi(next());
        else if (k == "--lights") a.lights = std::atoi(next());
        else if (k == "--frames") a.frames = std::atoi(next());
        else if (k == "--shot-at") a.shot_at = std::atoi(next());
        else if (k == "--density") a.density = static_cast<float>(std::atof(next()));
        else if (k == "--sens") a.sens = static_cast<float>(std::atof(next()));
        else if (k == "--no-crosshair") a.crosshair = false;
        else if (k == "--no-vsync") a.vsync = false;
        else if (k == "-h" || k == "--help") {
            std::printf("用法: game [--pack FILE] [--n 数量] [--w 宽] [--h 高]\n"
                        "            [--frames N] [--shot 图] [--shot-at 第几帧]\n"
                        "            [--lights 预算] [--density 密度] [--no-vsync] [--no-crosshair]\n");
            return 0;
        }
    }

    ContentPack pack;
    std::string err;
    if (!packio::load(a.pack, pack, &err)) {
        std::fprintf(stderr, "内容包读取失败: %s\n", err.c_str());
        return 1;
    }

    AppWindow win;
    if (!win.open(a.w, a.h, "开放架构 · 加载中", true, &err)) {
        std::fprintf(stderr, "开窗失败: %s\n", err.c_str());
        return 1;
    }
    if (!a.vsync) win.toggle_vsync();

    Renderer r;
    if (!r.init(pack, &err)) {
        std::fprintf(stderr, "渲染器初始化失败:\n%s\n", err.c_str());
        win.close();
        return 1;
    }
    r.uniform_consts();

    World world(pack, 120.0f, 30.0f, a.lights, 7, a.density);
    world.populate(static_cast<uint32_t>(a.n));

    Player player;
    player.reset(world.extent() * 0.5f, world.extent() * 0.5f, 0.0f);

    std::printf("GL  %s | %s\n", glGetString(GL_VERSION), glGetString(GL_RENDERER));
    std::printf("内容 %d 条，世界 %.0f × %.0f 米。WASD 移动，Esc 退出。\n", a.n,
                world.extent(), world.extent());

    std::vector<uint8_t> pixels;
    double last = now_s();
    float ema_ms = 0.0f;
    int frames = 0;
    Stats st;
    bool instancing = true;
    char title[256];

    for (;;) {
        const double t0 = now_s();
        float dt = static_cast<float>(t0 - last);
        last = t0;

        FrameInput fi = win.poll(a.sens);
        if (fi.quit) break;
        if (fi.toggle_instancing) {
            instancing = !instancing;
            std::printf("%s\n", instancing ? "合批：开" : "合批：关（一物一次提交）");
        }
        if (fi.toggle_vsync) {
            win.toggle_vsync();
            std::printf("垂直同步：%s\n", win.vsync() ? "开" : "关");
        }
        if (fi.recenter) player.reset(world.extent() * 0.5f, world.extent() * 0.5f, 0.0f);

        player.update(fi.in, dt, world.extent());
        if (std::getenv("GAME_DEBUG") && (frames % 5) == 0)
            std::printf("f%-3d pitch=%.3f yaw=%.3f look=(%.4f,%.4f) dt=%.3f\n", frames,
                        player.camera().pitch, player.camera().yaw, fi.in.look_dx, fi.in.look_dy,
                        dt);
        world.set_camera(player.x(), player.z(), player.yaw());
        st = world.step(instancing);
        r.draw(world, player.camera(), win.width(), win.height(), instancing, a.crosshair);

        if (a.shot && frames == (a.shot_at >= 0 ? a.shot_at : 30)) {
            int w = win.width(), h = win.height();
            pixels.resize(static_cast<size_t>(w) * h * 4);
            glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, pixels.data());
            if (write_ppm(a.shot, w, h, pixels)) std::printf("截图 -> %s\n", a.shot);
        }

        win.swap();

        const float frame_ms = static_cast<float>((now_s() - t0) * 1000.0);
        ema_ms = (frames == 0) ? frame_ms : ema_ms * 0.9f + frame_ms * 0.1f;
        ++frames;

        if (fi.released && !a.frames) {
            // 鼠标脱手时给个提示，否则玩家会以为鼠标坏了。
            std::snprintf(title, sizeof(title), "开放架构 · 已释放鼠标（点窗口任意处继续）");
        } else {
            std::snprintf(title, sizeof(title),
                          "开放架构 · %d 条内容 | %.0f fps | 可见 %u | %u draw | %.1fk 三角形 | "
                          "灯 %u/%u | %s | %s",
                          a.n, ema_ms > 0.0f ? 1000.0f / ema_ms : 0.0f, st.visible, st.draw_calls,
                          st.triangles / 1000.0, st.lights, st.lights + st.lights_capped,
                          instancing ? "合批" : "裸提交", win.vsync() ? "垂直同步" : "无限制");
        }
        if ((frames & 7) == 0) win.set_title(title);

        if (a.frames > 0 && frames >= a.frames) break;
    }

    win.close();

    std::printf("\n共 %d 帧，平均 %.2f ms/帧\n", frames, ema_ms);
    std::printf("最后一帧：驻留区块 %u / 驻留实体 %u / 激活 %u / 可见 %u\n", st.resident_chunks,
                st.resident_entities, st.active, st.visible);
    std::printf("提交 %u 次 draw call, %llu 个三角形, %u 盏动态光（收走 %u 盏）\n", st.draw_calls,
                static_cast<unsigned long long>(st.triangles), st.lights, st.lights_capped);
    return 0;
}
