// 最小数学库。不引 glm：这里只需要 4×4 矩阵和几个向量运算，
// 一个头文件 80 行搞定，编译时间是零。
#pragma once
#include <cmath>

struct Vec3 { float x, y, z; };

static inline Vec3 v3(float x, float y, float z) { return Vec3{x, y, z}; }
static inline Vec3 operator-(Vec3 a, Vec3 b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
static inline Vec3 operator+(Vec3 a, Vec3 b) { return {a.x + b.x, a.y + b.y, a.z + b.z}; }
static inline Vec3 operator*(Vec3 a, float s) { return {a.x * s, a.y * s, a.z * s}; }
static inline float dot(Vec3 a, Vec3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
static inline Vec3 cross(Vec3 a, Vec3 b) {
    return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}
static inline Vec3 normalize(Vec3 a) {
    float l = std::sqrt(dot(a, a));
    if (l < 1e-8f) l = 1.0f;
    return {a.x / l, a.y / l, a.z / l};
}

// 列主序，和 OpenGL 的约定一致：元素 (行 row, 列 col) 在 m[col*4+row]
struct Mat4 { float m[16]; };

static inline Mat4 mat_identity() {
    Mat4 r{};
    r.m[0] = r.m[5] = r.m[10] = r.m[15] = 1.0f;
    return r;
}

static inline Mat4 mat_mul(const Mat4& a, const Mat4& b) {
    Mat4 r{};
    for (int c = 0; c < 4; ++c)
        for (int row = 0; row < 4; ++row) {
            float s = 0.0f;
            for (int k = 0; k < 4; ++k) s += a.m[k * 4 + row] * b.m[c * 4 + k];
            r.m[c * 4 + row] = s;
        }
    return r;
}

static inline Mat4 mat_perspective(float fovy_rad, float aspect, float znear, float zfar) {
    float t = 1.0f / std::tan(fovy_rad * 0.5f);
    Mat4 r{};
    r.m[0] = t / aspect;
    r.m[5] = t;
    r.m[10] = (zfar + znear) / (znear - zfar);
    r.m[11] = -1.0f;
    r.m[14] = (2.0f * zfar * znear) / (znear - zfar);
    return r;
}

static inline Mat4 mat_look_at(Vec3 eye, Vec3 target, Vec3 up) {
    Vec3 f = normalize(target - eye);
    Vec3 s = normalize(cross(f, up));
    Vec3 u = cross(s, f);
    Mat4 r{};
    r.m[0] = s.x;  r.m[4] = s.y;  r.m[8]  = s.z;  r.m[12] = -dot(s, eye);
    r.m[1] = u.x;  r.m[5] = u.y;  r.m[9]  = u.z;  r.m[13] = -dot(u, eye);
    r.m[2] = -f.x; r.m[6] = -f.y; r.m[10] = -f.z; r.m[14] = dot(f, eye);
    r.m[15] = 1.0f;
    return r;
}
