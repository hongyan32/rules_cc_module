#pragma once

template<typename T>
class HeaderOnlyClass {
public:
    static T add(T a, T b) {
        return a + b;
    }
    
    static T multiply(T a, T b) {
        return a * b;
    }
};

// A simple header-only utility
inline int square(int x) {
    return x * x;
}
