// 图形 API 头。Linux 上 libGL 直接导出 3470 个 GL 符号，
// 所以不需要任何函数加载器 —— 这一层省掉了 300 行 glGetProcAddress 样板。
//
// 这里只引 GL，不引 EGL：窗口版走 GLX，离屏版才需要 EGL。
#pragma once
#ifndef GL_GLEXT_PROTOTYPES
#define GL_GLEXT_PROTOTYPES 1
#endif
#include <GL/gl.h>
#include <GL/glext.h>
