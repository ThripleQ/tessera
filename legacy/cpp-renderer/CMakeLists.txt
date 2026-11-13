cmake_minimum_required(VERSION 3.16)
project(game CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

# 两个产物，共享 src/renderer.hpp 里那一份绘制代码：
#   shot   离屏（EGL）—— 自检、出图、逐帧回放
#   game   窗口（GLX/X11）—— 真正能玩的那个
# 没有第三方依赖：GL 走系统 libGL（它直接导出全部 GL 符号），
# 上下文一个走 EGL、一个走 GLX，图像输出走自带 PPM 写出。
add_executable(shot src/shot.cpp)
target_compile_options(shot PRIVATE -O2 -Wall -Wextra -Wno-unused-parameter)
target_link_libraries(shot PRIVATE GL EGL m)

add_executable(game src/game.cpp)
target_compile_options(game PRIVATE -O2 -Wall -Wextra -Wno-unused-parameter)
target_link_libraries(game PRIVATE GL X11 m)

install(TARGETS shot game RUNTIME DESTINATION bin)
