// ============================================================
//  BLE 外设：手机（Central）连接后，把导航 JSON 写到 NAV 特征值。
//  服务/特征值 UUID 见 docs/protocol.md
// ============================================================
#include "ble_nav.h"

#include <Arduino.h>
#include <NimBLEDevice.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>

#include "config.h"
#include "map_nav.h"
#include "nav_data.h"
#include "ui.h"

namespace {

const char* SERVICE_UUID = "4e415647-5053-4c31-9000-000000000001";
const char* NAV_UUID     = "4e415647-5053-4c31-9000-000000000002";
const char* STATUS_UUID  = "4e415647-5053-4c31-9000-000000000003";

struct Packet {
  uint16_t len;
  char     data[220];
};

QueueHandle_t            s_queue  = nullptr;
NimBLEServer*            s_server = nullptr;
NimBLECharacteristic*    s_status = nullptr;
uint32_t                 s_lastStatusMs = 0;

class ServerCB : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* pServer, ble_gap_conn_desc* desc) override {
    g_nav.connected = true;
    g_nav.lastRxMs  = millis();
    ui::redraw();
    uint16_t handle = desc ? desc->conn_handle : 0;
    Serial.printf("[ble] 手机已连接, handle=%u MTU=%u\n", handle,
                  (unsigned)pServer->getPeerMTU(handle));
    // 30~60ms 连接间隔，兼顾实时性和功耗
    pServer->updateConnParams(handle, 24, 48, 0, 400);
  }

  void onDisconnect(NimBLEServer* pServer) override {
    g_nav.connected  = false;
    g_nav.navigating = false;
    g_nav.arrived    = false;
    g_nav.stale      = false;
    mapnav::reset();
    ui::redraw();
    Serial.println("[ble] 手机断开，等待重连");
    // NimBLE 默认会在断开后自动重新广播（advertiseOnDisconnect）
  }
};

class NavCB : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* pChr) override {
    auto v = pChr->getValue();
    if (v.length() == 0 || v.length() > sizeof(Packet::data)) return;

    Packet pkt;
    pkt.len = (uint16_t)v.length();
    memcpy(pkt.data, v.data(), v.length());

    if (xQueueSend(s_queue, &pkt, 0) != pdTRUE) {
      Serial.println("[ble] 队列满，丢一包");
    }
  }
};

void publishStatus(uint32_t now) {
  if (!s_status || now - s_lastStatusMs < 2000) return;
  s_lastStatusMs = now;

  char buf[128];
  snprintf(buf, sizeof(buf),
           "{\"fw\":\"%s\",\"up\":%lu,\"heap\":%u,\"conn\":%d,\"dev\":\"%s\"}", FW_VERSION,
           (unsigned long)(now / 1000), (unsigned)ESP.getFreeHeap(), g_nav.connected ? 1 : 0,
           DEVICE_NAME);
  s_status->setValue((uint8_t*)buf, strlen(buf));
  if (g_nav.connected) s_status->notify();
}

}  // namespace

namespace ble_nav {

void begin() {
  s_queue = xQueueCreate(4, sizeof(Packet));

  NimBLEDevice::init(DEVICE_NAME);
  NimBLEDevice::setMTU(BLE_MTU);
  NimBLEDevice::setPower(ESP_PWR_LVL_P9);

  s_server = NimBLEDevice::createServer();
  s_server->setCallbacks(new ServerCB());

  NimBLEService* svc = s_server->createService(SERVICE_UUID);

  NimBLECharacteristic* nav =
      svc->createCharacteristic(NAV_UUID, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
  nav->setCallbacks(new NavCB());

  s_status = svc->createCharacteristic(STATUS_UUID, NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY);
  s_status->setValue("{\"fw\":\"" FW_VERSION "\"}");

  svc->start();

  NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
  adv->addServiceUUID(SERVICE_UUID);
  adv->setScanResponse(true);
  adv->setMinPreferred(0x06);
  adv->setMinPreferred(0x12);
  NimBLEDevice::startAdvertising();

  Serial.printf("[ble] 广播中，名称 \"%s\"\n", DEVICE_NAME);
}

void poll() {
  if (!s_queue) return;

  Packet pkt;
  while (xQueueReceive(s_queue, &pkt, 0) == pdTRUE) {
    if (ui::demo()) {
      Serial.println("[ble] 收到手机数据，退出演示模式");
      ui::setDemo(false);
    }
    // '{' 开头是 JSON 导航状态，其余是二进制地图/位置包
    if (pkt.len && pkt.data[0] == '{') {
      if (navParseJson(pkt.data, pkt.len, g_nav)) {
        g_nav.connected = true;
        if (!g_nav.navigating && !g_nav.arrived) mapnav::reset();
      }
    } else {
      mapnav::handle((const uint8_t*)pkt.data, pkt.len);
    }
  }

  publishStatus(millis());
}

bool connected() { return g_nav.connected; }

}  // namespace ble_nav
