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

> Сделано: форк `vladimirdyskin/MinimedKit`, ветка `pickle-link-retry`. Submodule в форке
> iAPS (`pickle-link`) переключён на этот форк через `.gitmodules`.

## 9. Сделанные безопасные правки (этап A)

Форк MinimedKit, ветка `pickle-link-retry`, коммит `61cfa6c`:

| Файл:строка | Было | Стало | Обоснование |
| --- | --- | --- | --- |
| MinimedPumpMessageSender.swift:25 | timeout 200 мс | 300 мс | +50% окна поймать ответ при слабом сигнале (все чтения/wakeup) |
| PumpOpsSession.swift:112 | wakeup burst retry=0 | retry=1 | один доп. шанс разбудить спящую помпу |

Обе идемпотентны (чтения / wakeup) — без риска двойного дозирования.

Пауза между ретраями НЕ добавлена: `retryCount` исполняется прошивкой RileyLink
(`commandSession.sendAndListen`), а не Swift-циклом — это уже этап B.

## 10. Дизайн умного retry (этап B) — set → read-back → повтор

### Принцип
Ретраить только то, что ДОКАЗАННО не применилось. Не слепая переотправка, а
«проверь read-back → повтори только если не применилось».

### Опора: `setTempBasal` уже различает исходы (PumpOpsSession:510-560)

| Исход | Строка | Значение | Ретраить? |
| --- | --- | --- | --- |
| `.success(true)` | 547 | read-back подтвердил rate+duration | нет, успех |
| `.failure` wakeup/preflight | 518, 526 | команда не ушла (до отправки) | да — не применилось |
| `.failure(pumpError)` | 535 | помпа отвергла по логике | нет — повтор не поможет |
| `.failure` read-back mismatch | 554 | read-back: не та basal | да — не применилось |
| `.success(false)` | 558 | read-back не дочитался — неопределённость | только после повторного read-back |

### Алгоритм
```
setTempBasalPersistent(rate, duration, maxAttempts = 4):
    for attempt in 0..<maxAttempts:
        switch setTempBasal(rate, duration):
          .success(true)         -> return SUCCESS
          .failure(pumpError)    -> return FAILURE        // не повторять
          .failure(notSent | mismatch):
                backoff(attempt); continue                // доказано не применилось
          .success(false):                                // неопределённость
                if readTempBasal() == (rate,duration):
                     return SUCCESS
                else backoff(attempt); continue
    return last outcome
```
- backoff: 0.5s -> 1s -> 2s (восстановление радио, без агрессивного разряда)
- maxAttempts: 4, затем ошибка наверх (батарея/радио-эфир)
- каждая попытка логируется (отладка дублей)

### Bolus — отдельно и строже (РЕАЛИЗОВАНО)
Двойной болюс = передозировка. Опора — контракт `SetBolusError`:
`.certain` = болюс ТОЧНО не доставлен, `.uncertain` = аргументы ушли/ACK потерян
(мог начаться), `nil` = успех.

Обёртка `setNormalBolus` (`PumpOpsSession.swift`), `setNormalBolusOnce` = оригинал,
maxAttempts=3:

| Исход | Действие | Почему безопасно |
| --- | --- | --- |
| `nil` | стоп, успех | ACK получен |
| `.certain(rejection)` | стоп | bolusInProgress/suspended/pumpError — повтор не поможет |
| `.certain(comms)` | пауза 0.5s + повтор | болюс ТОЧНО не ушёл |
| `.uncertain`, доза ≥ 0.5U | читаем статус помпы (идемпотентно) | см. ниже |
| `.uncertain`, доза < 0.5U | стоп (как раньше) | микроболюс льётся секунды — окно защиты ненадёжно |

Для `.uncertain` ≥ 0.5U читаем `getPumpStatus().bolusing`:
- `true` → болюс реально идёт → `nil` (успех, IOB корректный, дубля нет)
- `false` → длинный болюс не начался → доставки не было → повтор безопасен
- статус не прочёлся → стоп (не рискуем)

**Опора на аппаратную защиту помпы:** во время доставки болюса помпа отвергает
новый болюс (`bolusInProgress`). Болюс ≥ 0.5U льётся ≈40 сек (новая помпа, 0.75 U/мин)
— дольше, чем повторное чтение статуса (~1.5–3 с), поэтому статус-чек однозначен.
Микроболюсы (< 0.5U, 4–24 сек) могут закончиться раньше → не ретраим.

Числа доставки: `PumpModel.bolusDeliveryTime` — новые помпы (gen≥23): <1U → 0.75 U/мин,
1–7.5U → 1.5 U/мин, >7.5U → units/5; старые — фиксировано 1.5 U/мин.

### Второй уровень (этап C) — APSManager
Сейчас после сбоя ждём полный loopInterval (270 с). Опция: при pumpError в
enactSuggested разрешить ранний повтор loop (~60 с вместо 270), не трогая обычный ритм.
Делать после того, как внутри-командный retry докажет себя.

### Где реализовать
- Уровень 1 (старт): обёртка `setTempBasalPersistent` в `PumpOpsSession` (MinimedKit) — есть и команда, и read-back.
- Уровень 2 (позже): ранний re-loop в APSManager.

### Риски / границы
- Не ретраим при `pumpError` и `.success(true)` — защита от дублей и зацикливания.
- maxAttempts + backoff — защита от разряда и радио-шторма.
- Bolus вне авто-retry — защита от передозировки.
