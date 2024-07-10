actor class Counter() {
    var counter: Nat = 0;

    public shared func increase(): async ()  {
        counter += 1;
    };

    public shared func get(): Nat {
        counter;
    };
}