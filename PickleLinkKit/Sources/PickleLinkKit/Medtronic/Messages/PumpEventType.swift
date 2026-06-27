public enum PumpEventType: UInt8 {
    case bolusNormal = 0x01
    case prime = 0x03
    case alarmPump = 0x06
    case resultDailyTotal = 0x07
    case changeBasalProfilePattern = 0x08
    case changeBasalProfile = 0x09
    case calBGForPH = 0x0A
    case alarmSensor = 0x0B
    case clearAlarm = 0x0C
    case selectBasalProfile = 0x14
    case tempBasalDuration = 0x16
    case changeTime = 0x17
    case newTime = 0x18
    case journalEntryPumpLowBattery = 0x19
    case battery = 0x1A
    case setAutoOff = 0x1B
    case suspend = 0x1E
    case resume = 0x1F
    case selftest = 0x20
    case rewind = 0x21
    case clearSettings = 0x22
    case changeChildBlockEnable = 0x23
    case changeMaxBolus = 0x24
    case enableDisableRemote = 0x26
    case changeMaxBasal = 0x2C
    case enableBolusWizard = 0x2D
    case changeBGReminderOffset = 0x31
    case changeAlarmClockTime = 0x32
    case tempBasal = 0x33
    case journalEntryPumpLowReservoir = 0x34
    case alarmClockReminder = 0x35
    case changeMeterId = 0x36
    case meterBGx15 = 0x39
    case questionable3b = 0x3B
    case changeParadigmLinkID = 0x3C
    case bgReceived = 0x3F
    case journalEntryMealMarker = 0x40
    case journalEntryExerciseMarker = 0x41
    case journalEntryInsulinMarker = 0x42
    case journalEntryOtherMarker = 0x43
    case changeSensorAutoCalEnable = 0x44
    case changeBolusWizardSetup = 0x4F
    case changeSensorSetup2 = 0x50
    case restoreMystery51 = 0x51
    case restoreMystery52 = 0x52
    case changeSensorAlarmSilenceConfig = 0x53
    case restoreMystery54 = 0x54
    case restoreMystery55 = 0x55
    case changeSensorRateOfChangeAlertSetup = 0x56
    case changeBolusScrollStepSize = 0x57
    case bolusWizardSetup = 0x5A
    case bolusWizardBolusEstimate = 0x5B
    case unabsorbedInsulin = 0x5C
    case saveSettings = 0x5D
    case changeVariableBolus = 0x5E
    case changeAudioBolus = 0x5F
    case changeBGReminderEnable = 0x60
    case changeAlarmClockEnable = 0x61
    case changeTempBasalType = 0x62
    case changeAlarmNotifyMode = 0x63
    case changeTimeFormat = 0x64
    case changeReservoirWarningTime = 0x65
    case changeBolusReminderEnable = 0x66
    case changeBolusReminderTime = 0x67
    case deleteBolusReminderTime = 0x68
    case bolusReminder = 0x69
    case deleteAlarmClockTime = 0x6A
    case dailyTotal515 = 0x6C
    case dailyTotal522 = 0x6D
    case dailyTotal523 = 0x6E
    case changeCarbUnits = 0x6F
    case basalProfileStart = 0x7B
    case changeWatchdogEnable = 0x7C
    case changeOtherDeviceID = 0x7D
    case changeWatchdogMarriageProfile = 0x81
    case deleteOtherDeviceID = 0x82
    case changeCaptureEventEnable = 0x83

    public var eventType: PumpEvent.Type {
        switch self {
        case .bolusNormal:
            return BolusNormalPumpEvent.self
        case .prime:
            return PrimePumpEvent.self
        case .alarmPump:
            return PumpAlarmPumpEvent.self
        case .resultDailyTotal:
            return ResultDailyTotalPumpEvent.self
        case .changeBasalProfilePattern:
            return ChangeBasalProfilePatternPumpEvent.self
        case .changeBasalProfile:
            return ChangeBasalProfilePumpEvent.self
        case .changeBolusWizardSetup:
            return ChangeBolusWizardSetupPumpEvent.self
        case .calBGForPH:
            return CalBGForPHPumpEvent.self
        case .alarmSensor:
            return AlarmSensorPumpEvent.self
        case .clearAlarm:
            return ClearAlarmPumpEvent.self
        case .tempBasalDuration:
            return TempBasalDurationPumpEvent.self
        case .changeTime:
            return ChangeTimePumpEvent.self
        case .newTime:
            return NewTimePumpEvent.self
        case .journalEntryPumpLowBattery:
            return JournalEntryPumpLowBatteryPumpEvent.self
        case .battery:
            return BatteryPumpEvent.self
        case .suspend:
            return SuspendPumpEvent.self
        case .resume:
            return ResumePumpEvent.self
        case .rewind:
            return RewindPumpEvent.self
        case .changeChildBlockEnable:
            return ChangeChildBlockEnablePumpEvent.self
        case .changeMaxBolus:
            return ChangeMaxBolusPumpEvent.self
        case .enableDisableRemote:
            return EnableDisableRemotePumpEvent.self
        case .changeMaxBasal:
            return ChangeMaxBasalPumpEvent.self
        case .enableBolusWizard:
            return EnableBolusWizardPumpEvent.self
        case .changeBGReminderOffset:
            return ChangeBGReminderOffsetPumpEvent.self
        case .tempBasal:
            return TempBasalPumpEvent.self
        case .journalEntryPumpLowReservoir:
            return JournalEntryPumpLowReservoirPumpEvent.self
        case .alarmClockReminder:
            return AlarmClockReminderPumpEvent.self
        case .changeParadigmLinkID:
            return ChangeParadigmLinkIDPumpEvent.self
        case .bgReceived:
            return BGReceivedPumpEvent.self
        case .journalEntryExerciseMarker:
            return JournalEntryExerciseMarkerPumpEvent.self
        case .journalEntryInsulinMarker:
            return JournalEntryInsulinMarkerPumpEvent.self
        case .journalEntryMealMarker:
            return JournalEntryMealMarkerPumpEvent.self
        case .changeSensorSetup2:
            return ChangeSensorSetup2PumpEvent.self
        case .changeSensorRateOfChangeAlertSetup:
            return ChangeSensorRateOfChangeAlertSetupPumpEvent.self
        case .changeBolusScrollStepSize:
            return ChangeBolusScrollStepSizePumpEvent.self
        case .bolusWizardSetup:
            return BolusWizardSetupPumpEvent.self
        case .bolusWizardBolusEstimate:
            return BolusWizardEstimatePumpEvent.self
        case .unabsorbedInsulin:
            return UnabsorbedInsulinPumpEvent.self
        case .changeVariableBolus:
            return ChangeVariableBolusPumpEvent.self
        case .changeAudioBolus:
            return ChangeAudioBolusPumpEvent.self
        case .changeBGReminderEnable:
            return ChangeBGReminderEnablePumpEvent.self
        case .changeAlarmClockEnable:
            return ChangeAlarmClockEnablePumpEvent.self
        case .changeTempBasalType:
            return ChangeTempBasalTypePumpEvent.self
        case .changeAlarmNotifyMode:
            return ChangeAlarmNotifyModePumpEvent.self
        case .changeTimeFormat:
            return ChangeTimeFormatPumpEvent.self
        case .changeReservoirWarningTime:
            return ChangeReservoirWarningTimePumpEvent.self
        case .changeBolusReminderEnable:
            return ChangeBolusReminderEnablePumpEvent.self
        case .changeBolusReminderTime:
            return ChangeBolusReminderTimePumpEvent.self
        case .deleteBolusReminderTime:
            return DeleteBolusReminderTimePumpEvent.self
        case .dailyTotal515:
            return DailyTotal515PumpEvent.self
        case .dailyTotal522:
            return DailyTotal522PumpEvent.self
        case .dailyTotal523:
            return DailyTotal523PumpEvent.self
        case .changeCarbUnits:
            return ChangeCarbUnitsPumpEvent.self
        case .basalProfileStart:
            return BasalProfileStartPumpEvent.self
        case .changeWatchdogEnable:
            return ChangeWatchdogEnablePumpEvent.self
        case .changeOtherDeviceID:
            return ChangeOtherDeviceIDPumpEvent.self
        case .changeWatchdogMarriageProfile:
            return ChangeWatchdogMarriageProfilePumpEvent.self
        case .deleteOtherDeviceID:
            return DeleteOtherDeviceIDPumpEvent.self
        case .changeCaptureEventEnable:
            return ChangeCaptureEventEnablePumpEvent.self
        case .selectBasalProfile:
            return SelectBasalProfilePumpEvent.self
        case .changeSensorAlarmSilenceConfig:
            return ChangeSensorAlarmSilenceConfigPumpEvent.self
        case .restoreMystery54:
            return RestoreMystery54PumpEvent.self
        case .restoreMystery55:
            return RestoreMystery55PumpEvent.self
        case .changeMeterId:
            return ChangeMeterIDPumpEvent.self
        case .bolusReminder:
            return BolusReminderPumpEvent.self
        case .meterBGx15:
            return BGReceivedPumpEvent.self
        default:
            return PlaceholderPumpEvent.self
        }
    }
}
