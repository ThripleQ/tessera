// 玩家控制器：把"按键"变成"相机"。窗口版和回放版共用这一份，
// 所以 --replay 录出来的走位，跟你手握 WASD 走出来的完全同一条曲线。
#pragma once
#include <cmath>

#include "mathx.hpp"
#include "renderer.hpp"

struct Input {
    float move_x = 0.0f;  // 右为正
    float move_z = 0.0f;  // 前为正
    float look_dx = 0.0f; // 弧度
    float look_dy = 0.0f;
    bool sprint = false;
};

class Player {
  public:
    void reset(float x, float z, float yaw) {
        x_ = x; z_ = z; yaw_ = yaw; pitch_ = -0.06f;
        vx_ = vz_ = 0.0f; bob_ = 0.0f;
    }

    void update(const Input& in, float dt, float extent) {
        if (dt > 0.1f) dt = 0.1f;  // 掉帧时不要让玩家瞬移

        yaw_ += in.look_dx;
        pitch_ += in.look_dy;
        if (pitch_ > 1.15f) pitch_ = 1.15f;
        if (pitch_ < -1.15f) pitch_ = -1.15f;

        // 本地 -> 世界。速度用指数平滑，手感上就是有惯性但不是冰面。
        const float c = std::cos(yaw_), s = std::sin(yaw_);
        float wx = in.move_x * c + in.move_z * s;
        float wz = -in.move_x * s + in.move_z * c;
        float len = std::sqrt(wx * wx + wz * wz);
        if (len > 1e-4f) { wx /= len; wz /= len; }

        const float top = in.sprint ? 13.0f : 7.0f;
        const float k = 1.0f - std::exp(-dt / 0.085f);
        vx_ += (wx * top - vx_) * k;
        vz_ += (wz * top - vz_) * k;

        x_ += vx_ * dt;
        z_ += vz_ * dt;

        const float margin = 2.0f;
        const float hi = extent - margin;
        if (x_ < margin) { x_ = margin; vx_ = 0.0f; }
        if (z_ < margin) { z_ = margin; vz_ = 0.0f; }
        if (x_ > hi) { x_ = hi; vx_ = 0.0f; }
        if (z_ > hi) { z_ = hi; vz_ = 0.0f; }

        // 头部起伏：速度越快越明显，站住就归零。
        const float sp = std::sqrt(vx_ * vx_ + vz_ * vz_);
        bob_ += sp * dt * 2.2f;
        bob_amp_ += ((sp > 0.6f ? 1.0f : 0.0f) - bob_amp_) * (1.0f - std::exp(-dt / 0.2f));
    }

    Camera camera() const {
        float y = 1.75f + std::sin(bob_ * 2.0f) * 0.045f * bob_amp_;
        float sway = std::cos(bob_) * 0.03f * bob_amp_;
        return Camera{v3(x_ + sway * std::cos(yaw_), y, z_ - sway * std::sin(yaw_)), yaw_, pitch_};
    }

    float x() const { return x_; }
    float z() const { return z_; }
    float yaw() const { return yaw_; }
    float speed() const { return std::sqrt(vx_ * vx_ + vz_ * vz_); }

  private:
    float x_ = 0.0f, z_ = 0.0f;
    float yaw_ = 0.0f, pitch_ = 0.0f;
    float vx_ = 0.0f, vz_ = 0.0f;
    float bob_ = 0.0f, bob_amp_ = 0.0f;
};
