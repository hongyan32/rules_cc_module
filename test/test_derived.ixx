// Derived module - depends on test_base1 and test_base2
export module test_derived;

import test_base1;  // This matches BUILD dependency: "test_base1"
import test_base2;  // This matches BUILD dependency: "test_base2"

export namespace test_derived {
    int get_combined_value() {
        return test_base1::get_value1() + test_base2::get_value2();
    }
    
    const char* get_combined_info() {
        return "test_derived: combines test_base1 and test_base2";
    }
    
    void show_dependencies() {
        // This function demonstrates that we actually use both base modules
        auto val1 = test_base1::get_value1();
        auto val2 = test_base2::get_value2();
        auto name1 = test_base1::get_name1();
        auto name2 = test_base2::get_name2();
    }
}