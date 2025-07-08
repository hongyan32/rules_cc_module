#include <iostream>
import scenarios;

int main() {
    std::cout << "--- Scenario 1: Function Template Specialization ---" << std::endl;
    std::cout << "Calling with int: ";
    scenario1_entry(1);
    std::cout << std::endl;

    std::cout << "Calling with string: ";
    scenario1_entry(std::string("one"));
    std::cout << std::endl;

    std::cout << "--- Scenario 2: Class Template Specialization ---" << std::endl;
    std::cout << "Calling with int: ";
    scenario2_entry(2);
    std::cout << std::endl;

    std::cout << "Calling with string: ";
    scenario2_entry(std::string("two"));
    std::cout << std::endl;

    std::cout << "--- Scenario 3: Class Template Member Function Specialization ---" << std::endl;
    std::cout << "Calling with int: ";
    scenario3_entry(3);
    std::cout << std::endl;

    std::cout << "Calling with string: ";
    scenario3_entry(std::string("three"));
    std::cout << std::endl;

    std::cout  << "--- Scenario 4: Class Template Member Function Specialization with Export ---" << std::endl;
    std::cout << "Calling with int: ";
    scenario4_entry(std::string("scenario4"),4);
    std::cout << std::endl;

    std::cout << "Calling with string: ";
    scenario4_entry(std::string("scenario4"), std::string("four"));
    std::cout << std::endl;

    return 0;
}
