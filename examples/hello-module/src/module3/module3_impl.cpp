module module3;

import module1;
import module2;

int multiply_and_add(int a, int b, int c) {
    int subtracted = subtract(a, b);
    return add(subtracted, c);
}
