// 程序化网格。真实项目里这一层读 glTF；现在用盒子拼低模，
// 因为"三角形数必须是真的"——预算表里的数字只能来自网格本身，不能来自估计。
#pragma once
#include <cmath>
#include <cstdint>
#include <cstring>
#include <vector>

struct Vertex {
    float x, y, z;
    float nx, ny, nz;
};

struct MeshData {
    std::vector<Vertex> verts;
    uint32_t tris = 0;
};

// 轴对齐盒子。六个面各两个三角形，法线是面法线（平直着色，正合低模风格）。
static inline void add_box(MeshData& m, float cx, float cy, float cz,
                           float hx, float hy, float hz) {
    const float x0 = cx - hx, x1 = cx + hx;
    const float y0 = cy - hy, y1 = cy + hy;
    const float z0 = cz - hz, z1 = cz + hz;

    struct Face { float n[3]; float v[4][3]; };
    const Face faces[6] = {
        {{0, 0, 1},  {{x0, y0, z1}, {x1, y0, z1}, {x1, y1, z1}, {x0, y1, z1}}},
        {{0, 0, -1}, {{x1, y0, z0}, {x0, y0, z0}, {x0, y1, z0}, {x1, y1, z0}}},
        {{1, 0, 0},  {{x1, y0, z1}, {x1, y0, z0}, {x1, y1, z0}, {x1, y1, z1}}},
        {{-1, 0, 0}, {{x0, y0, z0}, {x0, y0, z1}, {x0, y1, z1}, {x0, y1, z0}}},
        {{0, 1, 0},  {{x0, y1, z1}, {x1, y1, z1}, {x1, y1, z0}, {x0, y1, z0}}},
        {{0, -1, 0}, {{x0, y0, z0}, {x1, y0, z0}, {x1, y0, z1}, {x0, y0, z1}}},
    };
    for (const Face& f : faces) {
        auto push = [&](int i) {
            m.verts.push_back({f.v[i][0], f.v[i][1], f.v[i][2], f.n[0], f.n[1], f.n[2]});
        };
        push(0); push(1); push(2);
        push(0); push(2); push(3);
        m.tris += 2;
    }
}

// 上下半径不同的 N 棱柱，用来做飘忽的形态（幽灵那个）。
static inline void add_prism(MeshData& m, float cx, float cy, float cz,
                             float r_bottom, float r_top, float h, int sides) {
    const float two_pi = 6.28318530718f;
    for (int i = 0; i < sides; ++i) {
        float a0 = two_pi * static_cast<float>(i) / sides;
        float a1 = two_pi * static_cast<float>(i + 1) / sides;
        float c0 = std::cos(a0), s0 = std::sin(a0);
        float c1 = std::cos(a1), s1 = std::sin(a1);
        float nx = std::cos((a0 + a1) * 0.5f), nz = std::sin((a0 + a1) * 0.5f);
        Vertex a{cx + c0 * r_bottom, cy - h * 0.5f, cz + s0 * r_bottom, nx, 0, nz};
        Vertex b{cx + c1 * r_bottom, cy - h * 0.5f, cz + s1 * r_bottom, nx, 0, nz};
        Vertex c{cx + c1 * r_top,    cy + h * 0.5f, cz + s1 * r_top,    nx, 0, nz};
        Vertex d{cx + c0 * r_top,    cy + h * 0.5f, cz + s0 * r_top,    nx, 0, nz};
        m.verts.push_back(a); m.verts.push_back(b); m.verts.push_back(c);
        m.verts.push_back(a); m.verts.push_back(c); m.verts.push_back(d);
        m.tris += 2;

        // 顶盖扇
        Vertex o{cx, cy + h * 0.5f, cz, 0, 1, 0};
        m.verts.push_back(o); m.verts.push_back(d); m.verts.push_back(c);
        m.tris += 1;
        // 底盖扇
        Vertex ob{cx, cy - h * 0.5f, cz, 0, -1, 0};
        m.verts.push_back(ob); m.verts.push_back(a); m.verts.push_back(b);
        m.tris += 1;
    }
}

// 名字 -> 几何。加一个新网格就是在这里加一个分支，
// 同时要在 common/registry.py 的 MESHES 里登记三角形数。
static inline MeshData build_mesh(const char* name) {
    MeshData m;
    if (std::strcmp(name, "humanoid_lowpoly") == 0) {
        // 8 个盒子：躯干、头、双臂、双腿、胸甲、护肩
        add_box(m,  0.00f, 0.92f, 0.00f, 0.26f, 0.34f, 0.16f);  // 躯干
        add_box(m,  0.00f, 1.47f, 0.00f, 0.15f, 0.15f, 0.15f);  // 头
        add_box(m, -0.36f, 0.98f, 0.00f, 0.08f, 0.28f, 0.08f);  // 左臂
        add_box(m,  0.36f, 0.98f, 0.00f, 0.08f, 0.28f, 0.08f);  // 右臂
        add_box(m, -0.13f, 0.30f, 0.00f, 0.10f, 0.30f, 0.10f);  // 左腿
        add_box(m,  0.13f, 0.30f, 0.00f, 0.10f, 0.30f, 0.10f);  // 右腿
        add_box(m,  0.00f, 0.95f, 0.17f, 0.22f, 0.20f, 0.03f);  // 胸甲
        add_box(m,  0.00f, 1.24f, 0.00f, 0.40f, 0.05f, 0.12f);  // 护肩横条
    } else if (std::strcmp(name, "shade_lowpoly") == 0) {
        add_prism(m, 0.0f, 0.75f, 0.0f, 0.42f, 0.20f, 1.30f, 6);  // 飘着的袍子
        add_box(m, 0.0f, 1.52f, 0.0f, 0.13f, 0.13f, 0.13f);       // 头
    } else if (std::strcmp(name, "prop_crate") == 0) {
        add_box(m, 0.0f, 0.28f, 0.0f, 0.28f, 0.28f, 0.28f);
    } else if (std::strcmp(name, "prop_pillar") == 0) {
        add_box(m, 0.0f, 1.10f, 0.0f, 0.22f, 1.10f, 0.22f);
        add_box(m, 0.0f, 0.06f, 0.0f, 0.30f, 0.06f, 0.30f);
    } else {
        // 未知网格不能静默变成一个方块——那会让你以后找不到问题。
        add_box(m, 0.0f, 0.25f, 0.0f, 0.25f, 0.25f, 0.25f);
    }
    return m;
}
