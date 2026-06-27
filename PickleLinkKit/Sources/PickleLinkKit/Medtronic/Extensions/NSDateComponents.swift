import Foundation

extension DateComponents {
    init(mySentryBytes: Data) {
        self.init()

        hour = Int(mySentryBytes[0] & 0b0001_1111)
        minute = Int(mySentryBytes[1] & 0b0011_1111)
        second = Int(mySentryBytes[2] & 0b0011_1111)
        year = Int(mySentryBytes[3]) + 2000
        month = Int(mySentryBytes[4] & 0b0000_1111)
        day = Int(mySentryBytes[5] & 0b0001_1111)

        calendar = Calendar(identifier: .gregorian)
    }

    init(pumpEventData: Data, offset: Int, length: Int = 5) {
        self.init(pumpEventBytes: pumpEventData.subdata(in: offset ..< offset + length))
    }

    init(pumpEventBytes: Data) {
        self.init()

        if pumpEventBytes.count == 5 {
            second = Int(pumpEventBytes[0] & 0b0011_1111)
            minute = Int(pumpEventBytes[1] & 0b0011_1111)
            hour = Int(pumpEventBytes[2] & 0b0001_1111)
            day = Int(pumpEventBytes[3] & 0b0001_1111)
            month = Int((pumpEventBytes[0] & 0b1100_0000) >> 4) +
                Int((pumpEventBytes[1] & 0b1100_0000) >> 6)
            year = Int(pumpEventBytes[4] & 0b0111_1111) + 2000
        } else {
            day = Int(pumpEventBytes[0] & 0b0001_1111)
            month = Int((pumpEventBytes[0] & 0b1110_0000) >> 4) +
                Int((pumpEventBytes[1] & 0b1000_0000) >> 7)
            year = Int(pumpEventBytes[1] & 0b0111_1111) + 2000
        }

        calendar = Calendar(identifier: .gregorian)
    }

    init(glucoseEventBytes: Data) {
        self.init()

        year = Int(glucoseEventBytes[3] & 0b0111_1111) + 2000
        month = Int((glucoseEventBytes[0] & 0b1100_0000) >> 4) +
            Int((glucoseEventBytes[1] & 0b1100_0000) >> 6)
        day = Int(glucoseEventBytes[2] & 0b0001_1111)
        hour = Int(glucoseEventBytes[0] & 0b0001_1111)
        minute = Int(glucoseEventBytes[1] & 0b0011_1111)

        calendar = Calendar(identifier: .gregorian)
    }
}
