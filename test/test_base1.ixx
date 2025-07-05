// Base module 1 - no dependencies
export module test_base1;

export namespace test_base1 {
    int get_value1() {
        return 42;
    }
    
    const char* get_name1() {
        return "test_base1";
    }
}