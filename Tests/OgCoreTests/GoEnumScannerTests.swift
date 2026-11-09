import Testing
@testable import OgCore

@Suite struct GoEnumScannerTests {
    @Test func stringEnumWithConversion() {
        let src = """
        package p

        type TimeFormat string

        const (
        \tFormatDateTime TimeFormat = "datetime" // a
        \tFormatDateOnly TimeFormat = "date"
        )

        const Other = 3
        const RFC = TimeFormat("rfc3339")
        """
        let c = GoEnumScanner.constants(ofType: "TimeFormat", in: src)
        #expect(c.map(\.name) == ["FormatDateTime", "FormatDateOnly", "RFC"])
        #expect(c.map(\.value) == ["\"datetime\"", "\"date\"", "TimeFormat(\"rfc3339\")"])
    }

    @Test func iotaRepetitionSkipsBlank() {
        let src = """
        type Level int
        const (
        \tDebug Level = iota
        \tInfo
        \t_
        \tError
        )
        const (
        \tA Flag = 1 << iota
        \tB
        )
        """
        let c = GoEnumScanner.constants(ofType: "Level", in: src)
        #expect(c == [GoEnumConstant(name: "Debug", value: "0"), GoEnumConstant(name: "Info", value: "1"), GoEnumConstant(name: "Error", value: "3")])
        #expect(GoEnumScanner.constants(ofType: "Flag", in: src).map(\.value) == ["1", "2"])
    }

    @Test func ignoresUntypedAndLocalConsts() {
        let src = """
        const X = 1
        func f() {
        \tconst Local Level = 2
        }
        const (
        \tY = 2
        \tZ
        )
        """
        #expect(GoEnumScanner.constants(ofType: "Level", in: src).isEmpty)
    }
}
