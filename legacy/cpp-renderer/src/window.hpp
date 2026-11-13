// 窗口与输入：X11 + GLX，零第三方依赖。
//
// 为什么不用 GLFW：我们要的只有"一个能画的窗口 + 键盘鼠标状态"，
// 这两件事 Xlib 各一个函数。GLFW 会把 GLX 的选择权拿回去，
// 而我们恰恰需要控制 3.3 core / 双缓冲 / 无 MSAA 这几项。
#pragma once
#include <X11/XKBlib.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/keysym.h>

#include <cstdio>
#include <cstring>
#include <string>

#include "gl.hpp"
#include "player.hpp"

#ifndef GLX_GLXEXT_PROTOTYPES
#define GLX_GLXEXT_PROTOTYPES 1
#endif
#include <GL/glx.h>
#include <GL/glxext.h>

struct FrameInput {
    Input in;
    bool quit = false;
    bool toggle_instancing = false;
    bool toggle_vsync = false;
    bool recenter = false;
    bool released = false;  // 鼠标是否已经脱手（Esc 之后）
};

class AppWindow {
  public:
    bool open(int w, int h, const char* title, bool interactive, std::string* err) {
        w_ = w;
        h_ = h;
        interactive_ = interactive;

        dpy_ = XOpenDisplay(nullptr);
        if (!dpy_) { *err = "连不上 X（DISPLAY 没设置？）"; return false; }

        static int fb_attr[] = {
            GLX_X_RENDERABLE, True, GLX_DRAWABLE_TYPE, GLX_WINDOW_BIT,
            GLX_RENDER_TYPE, GLX_RGBA_BIT, GLX_X_VISUAL_TYPE, GLX_TRUE_COLOR,
            GLX_RED_SIZE, 8, GLX_GREEN_SIZE, 8, GLX_BLUE_SIZE, 8, GLX_ALPHA_SIZE, 8,
            GLX_DEPTH_SIZE, 24, GLX_DOUBLEBUFFER, True,
            GLX_SAMPLE_BUFFERS, 0, GLX_SAMPLES, 0,
            None};

        int n = 0;
        GLXFBConfig* fbc = glXChooseFBConfig(dpy_, DefaultScreen(dpy_), fb_attr, &n);
        if (!fbc || n < 1) { *err = "没有合适的 GLX framebuffer 配置"; return false; }
        GLXFBConfig cfg = fbc[0];
        XVisualInfo* vi = glXGetVisualFromFBConfig(dpy_, cfg);
        XFree(fbc);
        if (!vi) { *err = "glXGetVisualFromFBConfig 失败"; return false; }

        auto create_ctx = reinterpret_cast<PFNGLXCREATECONTEXTATTRIBSARBPROC>(
            glXGetProcAddressARB(reinterpret_cast<const GLubyte*>("glXCreateContextAttribsARB")));
        if (!create_ctx) { *err = "缺 glXCreateContextAttribsARB（驱动太老）"; return false; }

        const int ctx_attr[] = {GLX_CONTEXT_MAJOR_VERSION_ARB, 3,
                                GLX_CONTEXT_MINOR_VERSION_ARB, 3,
                                GLX_CONTEXT_PROFILE_MASK_ARB,
                                GLX_CONTEXT_CORE_PROFILE_BIT_ARB, None};
        ctx_ = create_ctx(dpy_, cfg, nullptr, True, ctx_attr);
        XFree(vi);
        if (!ctx_) { *err = "创建 3.3 core 上下文失败"; return false; }

        Window root = DefaultRootWindow(dpy_);
        XVisualInfo* vi2 = glXGetVisualFromFBConfig(dpy_, cfg);
        XSetWindowAttributes swa{};
        swa.colormap = cmap_ = XCreateColormap(dpy_, root, vi2->visual, AllocNone);
        swa.background_pixmap = None;
        swa.border_pixel = 0;
        swa.event_mask = StructureNotifyMask | ExposureMask | KeyPressMask | KeyReleaseMask |
                         ButtonPressMask;
        win_ = XCreateWindow(dpy_, root, 0, 0, w_, h_, 0, vi2->depth, InputOutput, vi2->visual,
                             CWBorderPixel | CWColormap | CWEventMask, &swa);
        XFree(vi2);

        Atom wm_delete = XInternAtom(dpy_, "WM_DELETE_WINDOW", False);
        XSetWMProtocols(dpy_, win_, &wm_delete, 1);
        wm_delete_ = wm_delete;
        set_title(title);

        XMapWindow(dpy_, win_);
        XFlush(dpy_);
        for (;;) {
            XEvent e;
            XNextEvent(dpy_, &e);
            if (e.type == MapNotify) break;
        }

        if (!glXMakeCurrent(dpy_, win_, ctx_)) { *err = "glXMakeCurrent 失败"; return false; }

        // 垂直同步：核显上开着更省电，测帧时间时用 --no-vsync 关掉。
        if (auto p = reinterpret_cast<PFNGLXSWAPINTERVALEXTPROC>(
                glXGetProcAddressARB(reinterpret_cast<const GLubyte*>("glXSwapIntervalEXT")))) {
            p(dpy_, win_, 1);
        } else if (auto m = reinterpret_cast<PFNGLXSWAPINTERVALMESAPROC>(
                       glXGetProcAddressARB(reinterpret_cast<const GLubyte*>("glXSwapIntervalMESA")))) {
            m(1);
        }
        vsync_ = true;

        if (interactive_) grab_pointer();
        return true;
    }

    // 每帧调一次：键盘状态直接问 X 服务器，不用自己维护事件队列。
    // 这样自动重复（按住不放产生的 KeyRelease/KeyPress 对）根本不会出问题 ——
    // 这是这类小引擎最省事也最不容易错的做法。
    FrameInput poll(float mouse_sens) {
        FrameInput out;
        char keys[32];
        XQueryKeymap(dpy_, keys);
        auto down = [&](KeySym sym) {
            KeyCode kc = XKeysymToKeycode(dpy_, sym);
            return kc && (keys[kc >> 3] & (1 << (kc & 7)));
        };

        if (down(XK_w) || down(XK_Up)) out.in.move_z += 1.0f;
        if (down(XK_s) || down(XK_Down)) out.in.move_z -= 1.0f;
        if (down(XK_d) || down(XK_Right)) out.in.move_x += 1.0f;
        if (down(XK_a) || down(XK_Left)) out.in.move_x -= 1.0f;
        out.in.sprint = down(XK_Shift_L) || down(XK_Shift_R);

        bool esc = down(XK_Escape);
        if (esc && !prev_esc_) {
            // 第一次 Esc 放开鼠标，第二次才退出 —— 别让手抖一下就把游戏关了。
            if (grabbed_) {
                ungrab();
            } else {
                out.quit = true;
            }
        }
        prev_esc_ = esc;

        bool b = down(XK_b);
        if (b && !prev_b_) out.toggle_instancing = true;
        prev_b_ = b;

        bool v = down(XK_v);
        if (v && !prev_v_) out.toggle_vsync = true;
        prev_v_ = v;

        bool r = down(XK_r);
        if (r && !prev_r_) out.recenter = true;
        prev_r_ = r;

        out.released = !grabbed_;

        if (grabbed_ && settle_ > 0) {
            // 刚抓鼠标 / 刚被窗口管理器改过尺寸时，指针位置还在跟窗口对账。
            // 这几帧的"位移"是环境抖动，不是玩家在转视角，必须丢掉，
            // 否则游戏一开局视线就已经歪了十几度。
            --settle_;
            center_warp();
        } else if (grabbed_) {
            Window ret_root, child;
            int rx = 0, ry = 0, wx = 0, wy = 0;
            unsigned mask = 0;
            if (XQueryPointer(dpy_, win_, &ret_root, &child, &rx, &ry, &wx, &wy, &mask)) {
                // 增量必须相对"上一次把指针挪到的位置"，不能相对当前窗口中心：
                // 窗口尺寸变了、或者合成器多挪了一像素，用中心算就会每帧
                // 凭空造出一个偏移，几十帧后视线就歪到天上去了。
                float dx = static_cast<float>(wx - warp_x_);
                float dy = static_cast<float>(wy - warp_y_);
                if (dx != 0.0f || dy != 0.0f) {
                    out.in.look_dx = dx * mouse_sens;
                    out.in.look_dy = -dy * mouse_sens;
                    center_warp();
                }
            }
        }

        // 关闭窗口 / 调整大小
        while (XPending(dpy_)) {
            XEvent e;
            XNextEvent(dpy_, &e);
            if (e.type == ClientMessage && static_cast<Atom>(e.xclient.data.l[0]) == wm_delete_)
                out.quit = true;
            else if (e.type == ButtonPress && interactive_ && !grabbed_)
                grab_pointer();  // 点一下窗口就把鼠标抓回来
            else if (e.type == ConfigureNotify) {
                if (e.xconfigure.width != w_ || e.xconfigure.height != h_) {
                    w_ = e.xconfigure.width;
                    h_ = e.xconfigure.height;
                    // 尺寸变了，中心也变了：把参照点挪过去，否则下一帧会算出一个大跳变。
                    if (grabbed_) { center_warp(); settle_ = 3; }
                }
            }
        }
        return out;
    }

    void swap() { glXSwapBuffers(dpy_, win_); }

    void set_title(const char* text) {
        // 中文标题必须走 _NET_WM_NAME + UTF8_STRING，XStoreName 是 latin1。
        Atom net_name = XInternAtom(dpy_, "_NET_WM_NAME", False);
        Atom utf8 = XInternAtom(dpy_, "UTF8_STRING", False);
        XChangeProperty(dpy_, win_, net_name, utf8, 8, PropModeReplace,
                        reinterpret_cast<const unsigned char*>(text), static_cast<int>(std::strlen(text)));
        XStoreName(dpy_, win_, text);
        XFlush(dpy_);
    }

    void toggle_vsync() {
        int v = vsync_ ? 0 : 1;
        if (auto p = reinterpret_cast<PFNGLXSWAPINTERVALEXTPROC>(
                glXGetProcAddressARB(reinterpret_cast<const GLubyte*>("glXSwapIntervalEXT")))) {
            p(dpy_, win_, v);
        } else if (auto m = reinterpret_cast<PFNGLXSWAPINTERVALMESAPROC>(
                       glXGetProcAddressARB(reinterpret_cast<const GLubyte*>("glXSwapIntervalMESA")))) {
            m(v);
        }
        vsync_ = !vsync_;
    }

    bool vsync() const { return vsync_; }
    bool grabbed() const { return grabbed_; }
    int width() const { return w_; }
    int height() const { return h_; }

    void close() {
        if (dpy_) {
            ungrab();
            if (blank_) XFreeCursor(dpy_, blank_);
            glXMakeCurrent(dpy_, None, nullptr);
            if (ctx_) glXDestroyContext(dpy_, ctx_);
            if (win_) XDestroyWindow(dpy_, win_);
            if (cmap_) XFreeColormap(dpy_, cmap_);
            XCloseDisplay(dpy_);
            dpy_ = nullptr;
        }
    }

  private:
    void center_warp() {
        warp_x_ = w_ / 2;
        warp_y_ = h_ / 2;
        XWarpPointer(dpy_, None, win_, 0, 0, 0, 0, warp_x_, warp_y_);
    }

    void ungrab() {
        if (!grabbed_) return;
        XUngrabPointer(dpy_, CurrentTime);
        XUndefineCursor(dpy_, win_);
        grabbed_ = false;
    }

    void grab_pointer() {
        // 1×1 全透明光标：桌面上的箭头消失，视线不会被自己挡住。
        char data = 0;
        Pixmap pm = XCreateBitmapFromData(dpy_, win_, &data, 1, 1);
        XColor black{};
        blank_ = XCreatePixmapCursor(dpy_, pm, pm, &black, &black, 0, 0);
        XFreePixmap(dpy_, pm);
        XDefineCursor(dpy_, win_, blank_);
        XGrabPointer(dpy_, win_, True, ButtonPressMask, GrabModeAsync, GrabModeAsync, win_,
                     blank_, CurrentTime);
        center_warp();
        grabbed_ = true;
        settle_ = 3;
    }

    Display* dpy_ = nullptr;
    ::Window win_ = 0;
    Colormap cmap_ = 0;
    GLXContext ctx_ = nullptr;
    Cursor blank_ = 0;
    Atom wm_delete_ = 0;
    int w_ = 0, h_ = 0;
    int warp_x_ = 0, warp_y_ = 0;  // 上一次把指针挪到哪（增量以此为参照）
    int settle_ = 0;               // 抓鼠标 / 改尺寸后的结算帧数，期间的位移丢弃
    bool interactive_ = false;
    bool grabbed_ = false;
    bool vsync_ = true;
    bool prev_esc_ = false, prev_b_ = false, prev_v_ = false, prev_r_ = false;
};
