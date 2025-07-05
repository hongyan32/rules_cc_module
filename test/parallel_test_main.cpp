#include <iostream>
import test_main;  // Import the top-level module

int main() {
    std::cout << "=== Parallel Compilation Test ===" << std::endl;
    
    // Test the final computed value
    int final_value = test_main::get_final_value();
    std::cout << "Final value: " << final_value << std::endl;
    
    // Expected calculation: (42 + 100) * 2 = 284
    int expected = (42 + 100) * 2;
    std::cout << "Expected: " << expected << std::endl;
    
    // Show module information
    std::cout << "Info: " << test_main::get_final_info() << std::endl;
    
    // Process all dependencies to ensure everything is working
    test_main::process_all();
    
    // Verify the result
    if (final_value == expected) {
        std::cout << "SUCCESS: Parallel compilation test passed!" << std::endl;
        return 0;
    } else {
        std::cout << "FAILURE: Expected " << expected << " but got " << final_value << std::endl;
        return 1;
    }
}