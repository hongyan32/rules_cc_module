// Main module - depends on test_derived
export module test_main;

import test_derived;  // This matches BUILD dependency: "test_derived"

export namespace test_main {
    int get_final_value() {
        return test_derived::get_combined_value() * 2;
    }
    
    const char* get_final_info() {
        return "test_main: final processing of derived values";
    }
    
    void process_all() {
        // This function demonstrates that we actually use test_derived
        auto combined = test_derived::get_combined_value();
        auto info = test_derived::get_combined_info();
        test_derived::show_dependencies();
    }
}