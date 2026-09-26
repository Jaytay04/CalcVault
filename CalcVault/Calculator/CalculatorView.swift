import SwiftUI

public struct CalculatorView: View {
    @StateObject private var model: CalculatorViewModel
    @State private var showingHistory = false
    @State private var showingConversions = false

    public init(model: CalculatorViewModel = CalculatorViewModel()) {
        _model = StateObject(wrappedValue: model)
    }

    public var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            VStack(spacing: CalculatorTheme.buttonSpacing) {
                display(landscape: landscape)
                if landscape {
                    HStack(alignment: .bottom, spacing: CalculatorTheme.buttonSpacing) {
                        scientificPad
                            .frame(maxWidth: .infinity)
                        basicPad
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        scientificStrip
                    }
                    basicPad
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .background(CalculatorTheme.background.ignoresSafeArea())
        }
        .navigationTitle("Calculator")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(CalculatorTheme.background, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                Button {
                    showingHistory = true
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                Button {
                    showingConversions = true
                } label: {
                    Label("Convert", systemImage: "arrow.left.arrow.right")
                }
            }
        }
        .sheet(isPresented: $showingHistory) {
            CalculatorHistoryView(model: model)
        }
        .sheet(isPresented: $showingConversions) {
            UnitConversionView()
        }
        .preferredColorScheme(.dark)
    }

    private func display(landscape: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(model.engine.expressionText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(model.engine.displayText)
                .font(.system(
                    size: landscape ? CalculatorTheme.landscapeDisplaySize : CalculatorTheme.portraitDisplaySize,
                    weight: .light,
                    design: .rounded
                ).monospacedDigit())
                .minimumScaleFactor(0.35)
                .lineLimit(1)
                .contentTransition(.numericText())
                .accessibilityLabel("Display")
                .accessibilityValue(model.engine.displayText)
        }
        .padding(.horizontal, CalculatorTheme.displayHorizontalPadding)
        .frame(maxWidth: .infinity)
    }

    private var basicPad: some View {
        Grid(horizontalSpacing: CalculatorTheme.buttonSpacing, verticalSpacing: CalculatorTheme.buttonSpacing) {
            GridRow {
                key(model.engine.clearButtonTitle, spoken: "Clear", kind: .function) { model.clear() }
                key("±", spoken: "Toggle sign", kind: .function) { model.toggleSign() }
                key("%", spoken: "Percent", kind: .function) { model.percent() }
                key("÷", spoken: "Divide", kind: .operation) { model.binary(.divide) }
            }
            GridRow {
                number(7); number(8); number(9)
                key("×", spoken: "Multiply", kind: .operation) { model.binary(.multiply) }
            }
            GridRow {
                number(4); number(5); number(6)
                key("−", spoken: "Subtract", kind: .operation) { model.binary(.subtract) }
            }
            GridRow {
                number(1); number(2); number(3)
                key("+", spoken: "Add", kind: .operation) { model.binary(.add) }
            }
            GridRow {
                key("⌫", spoken: "Delete", kind: .number) { model.deleteBackward() }
                number(0)
                key(".", spoken: "Decimal point", kind: .number) { model.decimal() }
                key("=", spoken: "Equals", kind: .operation) { model.equals() }
            }
        }
    }

    private var scientificStrip: some View {
        HStack(spacing: 8) {
            key("(", spoken: "Open parenthesis", kind: .scientific) { model.openParenthesis() }
            key(")", spoken: "Close parenthesis", kind: .scientific) { model.closeParenthesis() }
            key(model.engine.angleUnit.rawValue, spoken: "Angle unit", kind: .scientific) {
                model.angle(model.engine.angleUnit == .degrees ? .radians : .degrees)
            }
            key("sin", kind: .scientific) { model.scientific(.sine) }
            key("cos", kind: .scientific) { model.scientific(.cosine) }
            key("tan", kind: .scientific) { model.scientific(.tangent) }
            key("√", spoken: "Square root", kind: .scientific) { model.scientific(.squareRoot) }
            key("x²", spoken: "Square", kind: .scientific) { model.scientific(.square) }
            key("ln", kind: .scientific) { model.scientific(.naturalLog) }
            key("log", kind: .scientific) { model.scientific(.commonLog) }
            key("π", spoken: "Pi", kind: .scientific) { model.constant(.pi) }
            key("e", kind: .scientific) { model.constant(.e) }
        }
        .padding(.horizontal, 2)
    }

    private var scientificPad: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                key("(", kind: .scientific) { model.openParenthesis() }
                key(")", kind: .scientific) { model.closeParenthesis() }
                key(model.engine.angleUnit.rawValue, kind: .scientific) {
                    model.angle(model.engine.angleUnit == .degrees ? .radians : .degrees)
                }
                key("MC", kind: .scientific) { model.memory(.clear) }
                key("MR", kind: .scientific) { model.memory(.recall) }
            }
            GridRow {
                key("sin", kind: .scientific) { model.scientific(.sine) }
                key("cos", kind: .scientific) { model.scientific(.cosine) }
                key("tan", kind: .scientific) { model.scientific(.tangent) }
                key("M+", kind: .scientific) { model.memory(.add) }
                key("M−", kind: .scientific) { model.memory(.subtract) }
            }
            GridRow {
                key("sin⁻¹", kind: .scientific) { model.scientific(.inverseSine) }
                key("cos⁻¹", kind: .scientific) { model.scientific(.inverseCosine) }
                key("tan⁻¹", kind: .scientific) { model.scientific(.inverseTangent) }
                key("x²", kind: .scientific) { model.scientific(.square) }
                key("x³", kind: .scientific) { model.scientific(.cube) }
            }
            GridRow {
                key("√", kind: .scientific) { model.scientific(.squareRoot) }
                key("∛", kind: .scientific) { model.scientific(.cubeRoot) }
                key("1/x", kind: .scientific) { model.scientific(.reciprocal) }
                key("x!", kind: .scientific) { model.scientific(.factorial) }
                key("xʸ", kind: .scientific) { model.binary(.power) }
            }
            GridRow {
                key("ln", kind: .scientific) { model.scientific(.naturalLog) }
                key("log", kind: .scientific) { model.scientific(.commonLog) }
                key("eˣ", kind: .scientific) { model.scientific(.exponential) }
                key("10ˣ", kind: .scientific) { model.scientific(.tenPower) }
                key("π", kind: .scientific) { model.constant(.pi) }
            }
        }
    }

    private func number(_ value: Int) -> some View {
        key(String(value), kind: .number) { model.digit(value) }
    }

    private func key(
        _ title: String,
        spoken: String? = nil,
        kind: CalculatorKeyKind,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.title2.weight(.medium))
                .minimumScaleFactor(0.65)
                .frame(maxWidth: .infinity, minHeight: CalculatorTheme.minimumButtonHeight)
                .foregroundStyle(kind == .function ? Color.black : Color.white)
                .background(kind.color, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spoken ?? title)
    }
}

private enum CalculatorKeyKind {
    case number
    case function
    case operation
    case scientific

    var color: Color {
        switch self {
        case .number: CalculatorTheme.numberButton
        case .function: CalculatorTheme.functionButton
        case .operation: CalculatorTheme.operatorButton
        case .scientific: CalculatorTheme.scientificButton
        }
    }
}

private struct CalculatorHistoryView: View {
    @ObservedObject var model: CalculatorViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if model.history.isEmpty {
                    ContentUnavailableView("No History", systemImage: "clock")
                } else {
                    List(model.history) { entry in
                        Button {
                            model.reuse(entry)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(entry.expression)
                                    .foregroundStyle(.secondary)
                                Text(entry.result)
                                    .font(.title3.monospacedDigit())
                                    .foregroundStyle(.primary)
                            }
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                model.deleteHistory(entry)
                            }
                        }
                    }
                }
            }
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                if !model.history.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Clear", role: .destructive, action: model.clearHistory)
                    }
                }
            }
        }
    }
}

private struct UnitConversionView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var category: UnitConversion.Category = .length
    @State private var source: UnitConversion.Unit = .meter
    @State private var destination: UnitConversion.Unit = .kilometer
    @State private var input = "1"

    private var units: [UnitConversion.Unit] { UnitConversion.units(for: category) }

    private var output: String {
        guard let value = Double(input) else { return "Enter a number" }
        do {
            let result = try UnitConversion.convert(value, from: source, to: destination)
            return CalculatorFormatter().formatScientific(result)
        } catch {
            return "Unavailable"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Category", selection: $category) {
                    ForEach(UnitConversion.Category.allCases, id: \.self) { value in
                        Text(value.rawValue.capitalized).tag(value)
                    }
                }
                Picker("From", selection: $source) {
                    ForEach(units, id: \.self) { unit in
                        Text("\(unit.displayName) (\(unit.symbol))").tag(unit)
                    }
                }
                Picker("To", selection: $destination) {
                    ForEach(units, id: \.self) { unit in
                        Text("\(unit.displayName) (\(unit.symbol))").tag(unit)
                    }
                }
                TextField("Value", text: $input)
                    .keyboardType(.numbersAndPunctuation)
                LabeledContent("Result", value: output)
            }
            .navigationTitle("Convert")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: category) { _, newCategory in
                let values = UnitConversion.units(for: newCategory)
                source = values[0]
                destination = values[min(1, values.count - 1)]
            }
        }
    }
}
