// 世界层：分块 -> 激活 -> 视锥剔除 -> 合批。
//
// 这是 runtime/ecs.py + runtime/render.py 的 C++ 版，逐行对应，
// 目的是让两边的数字能对账 —— 如果对不上，说明有一边写错了。
#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <unordered_map>
#include <vector>

#include "mathx.hpp"
#include "pack.hpp"

static constexpr float CHUNK = 40.0f;
static constexpr float FOV_HALF = 0.6108652f;  // 35 度
static constexpr float DENSITY = 0.02f;

struct Entity {
    uint16_t proto = 0;
    uint16_t mesh = 0;
    uint16_t pal = 0;
    float x = 0.0f, z = 0.0f;
    float scale = 1.0f, yaw = 0.0f;
    bool has_light = false;
    float light_r = 0.0f, light_i = 0.0f;
};

struct Stats {
    uint32_t resident_chunks = 0;
    uint32_t resident_entities = 0;
    uint32_t active = 0;
    uint32_t visible = 0;
    uint32_t draw_calls = 0;
    uint64_t triangles = 0;
    uint32_t lights = 0;
    uint32_t lights_capped = 0;
};

// 一个 draw call 需要的全部东西：网格 + 一批实例。
struct Group {
    uint16_t mesh = 0;
    uint16_t pal = 0;
    std::vector<float> inst;  // 每条 8 个 float: x,y,z,scale, r,g,b,yaw
};

struct LightOut {
    float x, y, z, r;
    float intensity;
};

class World {
  public:
    World(const ContentPack& pack, float far = 120.0f, float radius = 30.0f,
          int light_budget = 8, uint32_t seed = 7, float density = DENSITY)
        : pack_(pack), far_(far), radius_(radius), light_budget_(light_budget), seed_(seed),
          density_(density) {}

    void populate(uint32_t n) {
        extent_ = std::fmax(80.0f, std::sqrt(static_cast<float>(n) / density_));
        entities_.clear();
        entities_.reserve(n);
        grid_.clear();

        if (pack_.protos.empty()) return;

        Rng rng(seed_);
        for (uint32_t i = 0; i < n; ++i) {
            const Proto& p = pack_.protos[i % pack_.protos.size()];
            Entity e;
            e.proto = static_cast<uint16_t>(i % pack_.protos.size());
            e.mesh = p.mesh;
            e.pal = p.palette;
            e.x = rng.unit() * extent_;
            e.z = rng.unit() * extent_;
            e.scale = p.scale;
            e.yaw = p.yaw;
            e.has_light = p.has_light != 0;
            e.light_r = p.light_radius;
            e.light_i = p.light_intensity;
            entities_.push_back(e);
        }
        for (uint32_t i = 0; i < entities_.size(); ++i) {
            const Entity& e = entities_[i];
            grid_[key(chunk_of(e.x), chunk_of(e.z))].push_back(i);
        }
        cam_x_ = extent_ * 0.5f;
        cam_z_ = extent_ * 0.5f;
        cam_yaw_ = 0.0f;
    }

    void move_camera(float t) {
        float m = std::fmax(10.0f, extent_ * 0.12f);
        float span = std::fmax(1.0f, extent_ - 2.0f * m);
        float x = m + span * (0.5f + 0.5f * std::sin(t * 0.31f));
        float z = m + span * (0.5f + 0.5f * std::sin(t * 0.17f + 1.3f));
        if (std::fabs(x - cam_x_) + std::fabs(z - cam_z_) > 1e-9f)
            cam_yaw_ = std::atan2(x - cam_x_, z - cam_z_);
        cam_x_ = x;
        cam_z_ = z;
    }

    Stats step(bool instancing) {
        Stats st;
        const float fx = std::sin(cam_yaw_);
        const float fz = std::cos(cam_yaw_);
        const float cos_half = std::cos(FOV_HALF);

        // 第一层：区块级粗剔除。整块不参与，后面的循环就省了。
        const int cgx = chunk_of(cam_x_);
        const int cgz = chunk_of(cam_z_);
        const int reach = static_cast<int>(far_ / CHUNK) + 1;

        cand_.clear();
        for (int gx = cgx - reach; gx <= cgx + reach; ++gx) {
            for (int gz = cgz - reach; gz <= cgz + reach; ++gz) {
                auto it = grid_.find(key(gx, gz));
                if (it == grid_.end()) continue;
                float bx = (gx + 0.5f) * CHUNK - cam_x_;
                float bz = (gz + 0.5f) * CHUNK - cam_z_;
                if (std::sqrt(bx * bx + bz * bz) > far_ + CHUNK * 1.5f) continue;
                ++st.resident_chunks;
                st.resident_entities += static_cast<uint32_t>(it->second.size());
                cand_.insert(cand_.end(), it->second.begin(), it->second.end());
            }
        }

        // 第二层：激活半径。可见但冻结的实体在这一层被挡住。
        const float r2 = radius_ * radius_;
        active_.clear();
        for (uint32_t idx : cand_) {
            const Entity& e = entities_[idx];
            float dx = e.x - cam_x_, dz = e.z - cam_z_;
            if (dx * dx + dz * dz <= r2) active_.push_back(idx);
        }
        st.active = static_cast<uint32_t>(active_.size());

        // 第三层：视锥 + 距离剔除
        const float far2 = far_ * far_;
        visible_.clear();
        for (uint32_t idx : cand_) {
            const Entity& e = entities_[idx];
            float dx = e.x - cam_x_, dz = e.z - cam_z_;
            float d2 = dx * dx + dz * dz;
            if (d2 > far2) continue;
            float d = std::sqrt(d2);
            if (d < 1e-6f || (dx * fx + dz * fz) / d >= cos_half) visible_.push_back(idx);
        }
        st.visible = static_cast<uint32_t>(visible_.size());

        // 第四层：合批。同一 (网格, 配色) 合并成一个 draw call。
        build_groups(instancing);
        st.draw_calls = static_cast<uint32_t>(groups_.size());
        for (const Group& g : groups_)
            st.triangles += static_cast<uint64_t>(g.inst.size() / 8) * pack_.meshes[g.mesh].tris;

        // 第五层：光源预算，由引擎强制，不由内容自觉。
        pick_lights(st);
        return st;
    }

    // 相机
    Vec3 eye() const { return v3(cam_x_, 2.9f, cam_z_); }
    Vec3 target() const {
        return v3(cam_x_ + std::sin(cam_yaw_) * 10.0f, 0.9f, cam_z_ + std::cos(cam_yaw_) * 10.0f);
    }
    float extent() const { return extent_; }
    float cam_x() const { return cam_x_; }
    float cam_z() const { return cam_z_; }
    float cam_yaw() const { return cam_yaw_; }
    const std::vector<Group>& groups() const { return groups_; }
    const std::vector<LightOut>& lights() const { return lights_out_; }

    void set_camera(float x, float z, float yaw) {
        cam_x_ = x; cam_z_ = z; cam_yaw_ = yaw;
    }

  private:
    struct Rng {
        uint32_t s;
        explicit Rng(uint32_t seed) : s(seed ? seed : 1u) {}
        uint32_t next() {
            s ^= s << 13; s ^= s >> 17; s ^= s << 5;
            return s;
        }
        float unit() { return (next() >> 8) * (1.0f / 16777216.0f); }
    };

    static int chunk_of(float v) { return static_cast<int>(std::floor(v / CHUNK)); }
    static uint64_t key(int gx, int gz) {
        return (static_cast<uint64_t>(static_cast<uint32_t>(gx)) << 32) |
               static_cast<uint32_t>(gz);
    }

    void build_groups(bool instancing) {
        // 用一条小数组代替 map：分组键只有 (mesh, pal) 几十种，线性查找比哈希快。
        groups_.clear();
        for (uint32_t idx : visible_) {
            const Entity& e = entities_[idx];
            Group* g = nullptr;
            if (instancing) {
                for (Group& cand : groups_)
                    if (cand.mesh == e.mesh && cand.pal == e.pal) { g = &cand; break; }
                if (!g) {
                    groups_.push_back(Group{e.mesh, e.pal, {}});
                    g = &groups_.back();
                }
            } else {
                // 关掉实例化：一物一次提交，用来看清合批到底值多少
                groups_.push_back(Group{e.mesh, e.pal, {}});
                g = &groups_.back();
            }
            Vec3 c = palette_color(e.pal);
            g->inst.push_back(e.x);
            g->inst.push_back(0.0f);
            g->inst.push_back(e.z);
            g->inst.push_back(e.scale);
            g->inst.push_back(c.x);
            g->inst.push_back(c.y);
            g->inst.push_back(c.z);
            g->inst.push_back(e.yaw * 0.0174532925f);
        }
    }

    Vec3 palette_color(uint16_t pal) const {
        static const Vec3 known[] = {
            {0.86f, 0.82f, 0.70f},   // bone
            {0.52f, 0.32f, 0.72f},   // violet
            {0.52f, 0.36f, 0.22f},   // wood
        };
        if (pal < pack_.palettes.size()) {
            const std::string& n = pack_.palettes[pal];
            if (n == "bone") return known[0];
            if (n == "violet") return known[1];
            if (n == "wood") return known[2];
            // 没登记过的新配色不能让画面崩，用名字哈希出一色。
            // 这样"加内容不用改代码"在颜色上也成立。
            uint32_t h = 2166136261u;
            for (char ch : n) { h ^= static_cast<uint8_t>(ch); h *= 16777619u; }
            return v3(0.28f + 0.62f * ((h >> 0) & 0xFF) / 255.0f,
                      0.28f + 0.62f * ((h >> 8) & 0xFF) / 255.0f,
                      0.28f + 0.62f * ((h >> 16) & 0xFF) / 255.0f);
        }
        return v3(0.6f, 0.6f, 0.6f);
    }

    void pick_lights(Stats& st) {
        lights_out_.clear();
        lit_tmp_.clear();
        for (uint32_t idx : visible_) {
            const Entity& e = entities_[idx];
            if (!e.has_light || e.light_i <= 0.0f) continue;
            lit_tmp_.push_back(idx);
        }
        const int budget = light_budget_;
        if (static_cast<int>(lit_tmp_.size()) <= budget) {
            st.lights = static_cast<uint32_t>(lit_tmp_.size());
            st.lights_capped = 0;
        } else {
            std::sort(lit_tmp_.begin(), lit_tmp_.end(), [&](uint32_t a, uint32_t b) {
                float da = (entities_[a].x - cam_x_) * (entities_[a].x - cam_x_) +
                           (entities_[a].z - cam_z_) * (entities_[a].z - cam_z_);
                float db = (entities_[b].x - cam_x_) * (entities_[b].x - cam_x_) +
                           (entities_[b].z - cam_z_) * (entities_[b].z - cam_z_);
                return da < db;
            });
            st.lights = static_cast<uint32_t>(budget);
            st.lights_capped = static_cast<uint32_t>(lit_tmp_.size() - budget);
            lit_tmp_.resize(static_cast<size_t>(budget));
        }
        for (uint32_t idx : lit_tmp_) {
            const Entity& e = entities_[idx];
            lights_out_.push_back(LightOut{e.x, 1.5f, e.z, e.light_r, e.light_i});
        }
    }

    const ContentPack& pack_;
    float far_, radius_;
    int light_budget_;
    uint32_t seed_;
    float density_;
    float extent_ = 200.0f;
    float cam_x_ = 0.0f, cam_z_ = 0.0f, cam_yaw_ = 0.0f;

    std::vector<Entity> entities_;
    std::unordered_map<uint64_t, std::vector<uint32_t>> grid_;
    std::vector<uint32_t> cand_, active_, visible_, lit_tmp_;
    std::vector<Group> groups_;
    std::vector<LightOut> lights_out_;
};
