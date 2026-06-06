# Управление помпой Medtronic/Minimed в iAPS — карта связи и ретраев

> Анализ потока команд, тайминга и точек отказа связи. Цель — сделать связь
> настойчивее (ретраить, а не ждать цикл и слать уведомление).
> Источник: multi-agent разбор MinimedKit + RileyLink + APSManager/DeviceDataManager.

## 1. Три слоя управления

```
APSManager (FreeAPS)          РЕШАЕТ что слать: temp basal / bolus, раз в цикл
  loop() ~каждые 270 сек
    │
MinimedKit (PumpOpsSession)   ФОРМИРУЕТ Carelink-команды, wakeup, retry-логика
  getResponse(retryCount:)
    │
RileyLink (CommandSession)    РАДИО: шлёт пакет N раз, слушает ответ
  sendAndListen(repeatCount:, timeout:, retryCount:)
```

## 2. Тайминг — что и когда

| Событие | Период | Действие |
| --- | --- | --- |
| Heartbeat (RileyLink BLE tick) | по тику радио | запускает цепочку обновления |
| CGM новые данные | ~5 мин | главный триггер → опрос помпы → loop |
| updatePumpData | при CGM/heartbeat | читает status, battery, reservoir, history page |
| loop() | 270 сек (опц. 50 сек) | determineBasal → enactSuggested (TB/болюс) |
| «too close to do a loop» | если < интервала от старта прошлого | пропуск цикла |
| Уведомление «iAPS not active» | 20 и 40 мин без успешного loop | UserNotificationsManager |

Цепочка: `CGM reading → updatePumpData → _recommendsLoop.send() → (debounce 1с) → loop() → enactTempBasal/Bolus`.

Ключевые ссылки:
- `FreeAPS/Sources/APS/DeviceDataManager.swift:573` — pumpManagerBLEHeartbeatDidFire
- `FreeAPS/Sources/APS/DeviceDataManager.swift:284` — updatePumpData
- `FreeAPS/Sources/APS/APSManager.swift:202` — loop()
- `FreeAPS/Sources/Config/Config.swift:7-8` — loopIntervalFiveMinutes=270, loopIntervalOneMinute=50

## 3. Поток одной команды помпе

1. **wakeup** (помпа засыпает через ~1–2 мин неактивности):
   - burst `repeatCount=255`, слушает 12 сек — `PumpOpsSession.swift:112`, **retryCount=0**
   - затем PowerOn-сообщение `retryCount=3` — `PumpOpsSession.swift:157`
2. **getResponse**: пакет → RileyLink шлёт → слушает 200 мс (+2с BLE) → если тихо, повтор `retryCount` раз
3. Нет ответа после всех попыток → `PumpOpsError.noResponse` (`MinimedPumpMessageSender.swift:152`)

«No pump responses during scan» (`PumpOpsSession.swift:939`) = перебрал все 8–9 частот × 3 попытки (~72 попытки, ~16 сек), ноль ответов.

## 4. Текущие retry/timeout (захардкожено)

| Файл:строка | Операция | Значение |
| --- | --- | --- |
| MinimedPumpMessageSender.swift:25 | стандартное окно ответа | timeout = 200 мс |
| PumpOpsSession.swift:106 | wakeup burst (short) | repeat=255, timeout=1 мс, retry=0 |
| PumpOpsSession.swift:112 | wakeup burst (power-on) | repeat=255, timeout=12 с, **retry=0** |
| PumpOpsSession.swift:120 | isPumpResponding | timeout=200 мс, retry=1 |
| PumpOpsSession.swift:157 | wakeup (основной) | retry=3 |
| PumpOpsSession.swift:191-388 | чтение (модель/батарея/статус) | retry=3, timeout=200 мс |
| PumpOpsSession.swift:532 | **SET temp basal** | **retry=1** |
| Config.swift:7 | интервал цикла | 270 сек |

Backoff отсутствует везде — только фиксированные числа, без пауз между попытками.

## 5. Где iAPS «сдаётся» при потере связи

Проблема НЕ в радио-слое (там ретраи есть), а в двух местах:

### 5.1 loopInterval блокирует немедленный повтор — `APSManager.swift:202-210`
```
10:00:00  loop стартует
10:00:01  enactTempBasal → noResponse
10:00:02  приходит CGM → loop() снова → "too close" → ВЫХОД
10:04:30  только теперь следующая попытка   ← ждём 4.5 минуты
```
После сбоя нет переподключения за 1–2 сек — ждём целый цикл, через 20/40 мин уведомление.

### 5.2 Слабые ретраи на критичных командах
- wakeup power-on: retry=0
- SET temp basal: retry=1 (всего 2 попытки на важнейшую команду)
- нет пауз между ретраями

### Таблица точек отказа

| Сценарий | Точка | Поведение | Retry? |
| --- | --- | --- | --- |
| Temp basal не отправился | enactSuggested → error | loop FAILED, lastLoopDate не обновлён | через 4.5 мин |
| Bolus не отправился | enactSuggested → error | loop FAILED | через 4.5 мин |
| Pump not reachable | verifyStatus error | loop STOPS | через 4.5 мин |
| Ручной болюс failed | enactBolus.sink error | processError + уведомление | пользователь вручную |

## 6. План усиления — безопасное → умное

### Этап A. Безопасные правки (низкий риск)
| Место | Сейчас | Стало | Риск |
| --- | --- | --- | --- |
| PumpOpsSession.swift:112 wakeup | retry=0 | retry=3 | низкий (пробуждение идемпотентно) |
| MinimedPumpMessageSender.swift:25 timeout | 200 мс | 300–400 мс | низкий (окно для слабого сигнала) |
| между ретраями | нет паузы | sleep 100–200 мс | низкий (помпе нужно «отдышаться») |

### Этап B. Умный retry для temp basal (set → read-back → повтор)
Temp basal НЕ идемпотентен на слепом повторе: если помпа применила команду, но ACK
потерялся, повтор задаст её второй раз. MinimedKit уже страхуется — после set читает
`readTempBasal` (`PumpOpsSession.swift:543`). Любой агрессивный retry строить ПОВЕРХ
этой верификации:
```
set temp basal
  → read-back (readTempBasal)
      применилось? → success
      нет?         → повтор (с backoff), не более N раз
```
Только так настойчивость не приводит к двойному дозированию.

## 7. ⚠️ Главный риск
**Дубли команд.** Любое усиление ретраев на temp basal/bolus обязано опираться на
read-back верификацию, а не на слепую переотправку. Status-запросы (чтение) можно
ретраить свободно — они идемпотентны.

## 8. ВАЖНО: MinimedKit — это git submodule
Правки в `MinimedKit/...` идут в отдельный репозиторий (upstream Artificial-Pancreas/MinimedKit),
а НЕ в форк iAPS. Чтобы версионировать изменения — нужен форк MinimedKit или хранить
правки локально. Решить до начала кодинга.
