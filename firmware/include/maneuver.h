#pragma once
#include <LovyanGFX.hpp>
#include <stdint.h>

#include "nav_data.h"

// 在 (cx, cy) 处画一个 size 像素见方的转向图标。
// 图标全部用几何图形现画，不占 Flash，也不会模糊。
void drawManeuverIcon(LovyanGFX& g, Maneuver m, int cx, int cy, int size, uint16_t color);
