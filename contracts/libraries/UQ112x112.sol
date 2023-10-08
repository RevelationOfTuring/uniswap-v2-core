pragma solidity =0.5.16;

// a library for handling binary fixed point numbers (https://en.wikipedia.org/wiki/Q_(number_format))

// range: [0, 2**112 - 1]
// resolution: 1 / 2**112

// UQ112x112库会被UniswapV2Pair合约中的uint224类型使用
// token的数量可能会出现小数，而solidity中没有非整数类型，所以使用该库去模拟浮点数。
// 将unit224中的高112位当作浮点数的整数部分，低112位当作浮点数的小数部分。
// 这样表示数字的范围为[0, 2**112 - 1]，精度为1 / 2**112
library UQ112x112 {
    uint224 constant Q112 = 2**112;

    // encode a uint112 as a UQ112x112
    // 将uint112变成UQ112x112表示的uint224
    function encode(uint112 y) internal pure returns (uint224 z) {
        // 即将y左移112位，变成uint224（该操作不会溢出）
        z = uint224(y) * Q112; // never overflows
    }

    // divide a UQ112x112 by a uint112, returning a UQ112x112
    // 计算UQ112x112表示的uint224类型的x与uint112类型的y的商，计算结果仍使用UQ112x112表示
    // ps：该返回值的高112位表示商的整数部分，而低112为表示商的小数部分
    function uqdiv(uint224 x, uint112 y) internal pure returns (uint224 z) {
        z = x / uint224(y);
    }
}
