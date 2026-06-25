actor LockedValue<Value> {
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        value
    }

    func set(_ value: Value) {
        self.value = value
    }

    func withValue(_ update: (inout Value) -> Void) {
        update(&value)
    }

    func append<Element>(_ newElement: Element) where Value == [Element] {
        value.append(newElement)
    }
}
