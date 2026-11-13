// 内容包读取。格式由 tools/contentc.py 的 emit_binary 定义，version 必须对上。
//
// 这里刻意不做任何"智能"处理：没有反射、没有字段名查表、没有字符串比较。
// 3 万个实体读进来就是一次 fread，读到的就是渲染和逻辑要的那几个数。
#pragma once
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

struct ProtoMesh {
    std::string name;
    uint32_t tris = 0;
};

// 可摆放的原型（archetype 且有外观）。世界里的每个实体都是它的克隆。
struct Proto {
    std::string cid;
    uint16_t mesh = 0;
    uint16_t palette = 0;
    float scale = 1.0f;
    float yaw = 0.0f;
    uint8_t has_light = 0;
    float light_radius = 0.0f;
    float light_intensity = 0.0f;
    float move_speed = 0.0f;
    float aggro_radius = 0.0f;
};

struct ContentPack {
    std::vector<ProtoMesh> meshes;
    std::vector<std::string> palettes;
    std::vector<Proto> protos;

    int mesh_index(const char* name) const {
        for (size_t i = 0; i < meshes.size(); ++i)
            if (meshes[i].name == name) return static_cast<int>(i);
        return -1;
    }
};

namespace packio {

class Reader {
  public:
    Reader(const uint8_t* d, size_t n) : d_(d), n_(n) {}
    bool ok() const { return ok_; }
    size_t pos() const { return p_; }

    template <typename T> T take() {
        if (p_ + sizeof(T) > n_) { ok_ = false; return T{}; }
        T v;
        std::memcpy(&v, d_ + p_, sizeof(T));
        p_ += sizeof(T);
        return v;
    }
    std::string str16() {
        uint16_t len = take<uint16_t>();
        if (p_ + len > n_) { ok_ = false; return {}; }
        std::string s(reinterpret_cast<const char*>(d_ + p_), len);
        p_ += len;
        return s;
    }

  private:
    const uint8_t* d_;
    size_t n_;
    size_t p_ = 0;
    bool ok_ = true;
};

static inline bool load(const char* path, ContentPack& out, std::string* err) {
    FILE* f = std::fopen(path, "rb");
    if (!f) { *err = std::string("打不开 ") + path; return false; }
    std::fseek(f, 0, SEEK_END);
    long sz = std::ftell(f);
    std::fseek(f, 0, SEEK_SET);
    std::vector<uint8_t> buf(static_cast<size_t>(sz));
    if (std::fread(buf.data(), 1, buf.size(), f) != buf.size()) {
        std::fclose(f);
        *err = "读取不完整";
        return false;
    }
    std::fclose(f);

    if (buf.size() < 8 || std::memcmp(buf.data(), "CGPK", 4) != 0) {
        *err = "不是内容包（magic 不对）";
        return false;
    }
    Reader r(buf.data() + 4, buf.size() - 4);
    uint32_t ver = r.take<uint32_t>();
    if (ver != 2) {
        *err = "内容包版本不符，要 2，读到 " + std::to_string(ver) + "。重跑 contentc.py";
        return false;
    }

    uint32_t nm = r.take<uint32_t>();
    for (uint32_t i = 0; i < nm; ++i) {
        ProtoMesh m;
        m.name = r.str16();
        m.tris = r.take<uint32_t>();
        out.meshes.push_back(std::move(m));
    }
    uint32_t np = r.take<uint32_t>();
    for (uint32_t i = 0; i < np; ++i) out.palettes.push_back(r.str16());

    uint32_t ne = r.take<uint32_t>();
    for (uint32_t i = 0; i < ne; ++i) {
        Proto p;
        p.cid = r.str16();
        r.take<uint8_t>();  // kind，渲染侧暂时不用
        p.mesh = r.take<uint8_t>();
        p.palette = r.take<uint16_t>();
        p.scale = r.take<float>();
        p.yaw = r.take<float>();
        p.light_radius = r.take<float>();
        p.light_intensity = r.take<float>();
        p.move_speed = r.take<float>();
        p.aggro_radius = r.take<float>();
        p.has_light = r.take<uint8_t>();
        out.protos.push_back(std::move(p));
    }

    if (!r.ok()) { *err = "内容包被截断"; return false; }
    return true;
}

}  // namespace packio
