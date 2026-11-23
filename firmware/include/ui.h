#pragma once
#include <stdint.h>

#include "nav_data.h"

namespace ui {

// 初始化画布（优先用 Sprite 双缓冲，没内存就直画）
void begin();

// 主循环里调用，内部自己控制刷新率
void tick(uint32_t nowMs);

// 强制下一帧重画
void redraw();

// 演示模式（没有手机时也能看界面）
void setDemo(bool on);
bool demo();

}  // namespace ui
