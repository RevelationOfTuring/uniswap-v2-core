pragma solidity =0.5.16;

import './interfaces/IUniswapV2Pair.sol';
import './UniswapV2ERC20.sol';
import './libraries/Math.sol';
import './libraries/UQ112x112.sol';
import './interfaces/IERC20.sol';
import './interfaces/IUniswapV2Factory.sol';
import './interfaces/IUniswapV2Callee.sol';

// UniswapV2Pair合约本身就是一个ERC20，即LP token
contract UniswapV2Pair is IUniswapV2Pair, UniswapV2ERC20 {
    using SafeMath  for uint;
    // 为uint224类型赋予UQ112x112库
    using UQ112x112 for uint224;

    // 最小流动性的定义是1000
    // 在首次铸币的时候，会要求调用者提供大于MININUM_LIQUIDITY数量的流动性
    // 这是为了防止有人抬高流动性单价进而垄断交易对，使得后面的交易者无力参与，即抬高添加流动性的成本
    // 攻击手法：
    // 步骤1：1 token0 + 1 token1 添加流动性，获得1个LP token
    //       注：此时total supply/reverse0/reverse1均为1
    // 步骤2：转移1000 token0给pair，不调用mint()，而是调用sync()
    //       注：此时total supply为1，reverse0为1000，reverse1为1，此时1个LP token的就等于1000 token0+1 token1
    //          后面的流动性添加者就需要按照1000 token0+1 token1的价值来添加流动性了
    uint public constant MINIMUM_LIQUIDITY = 10 ** 3;
    // 调用ERC20的transfer函数时的selector
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)')));

    // factory合约地址
    address public factory;
    // 构成交易对的两种ERC20代币地址
    address public token0;
    address public token1;

    // 一下三个变量共占256位，存储在一个slot中
    // reserve0为token0的储备量
    uint112 private reserve0;           // uses single storage slot, accessible via getReserves
    // reserve1为token1的储备量
    uint112 private reserve1;           // uses single storage slot, accessible via getReserves
    // 最近一次更新reserve0和reserve1时（调用_update()）的区块时间戳
    // 主要用于判断当前交易是不是该区块的中第一笔交易调用调用_update()的交易
    uint32  private blockTimestampLast; // uses single storage slot, accessible via getReserves

    // 价格的累计值，为Uniswap V2所提供的价格预言机服务。
    // price0CumulativeLast和price1CumulativeLast会在一个区块中第一笔调用_update()的交易中更新
    uint public price0CumulativeLast;
    uint public price1CumulativeLast;

    // k值
    // 该变量在没有开启平台收费的时候为0。当开启平台收费时，该变量才等于k值
    // ps: 因为开启平台收费时，那么k值往往不会一直等于reserve0 * reserve1
    uint public kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event

    // 防重入锁
    uint private unlocked = 1;
    modifier lock() {
        require(unlocked == 1, 'UniswapV2: LOCKED');
        unlocked = 0;
        _;
        unlocked = 1;
    }

    // 返回当前pair的两种token的储备量和上一个调用了_update()的区块时间戳
    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    // 转移ERC20 token
    function _safeTransfer(address token, address to, uint value) private {
        // 调用token合约的transfer(address,uint256)方法
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        // 如果上面的call调用成功且call的无返回值或返回值是true，表示ERC20代币转移成功，否则revert
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'UniswapV2: TRANSFER_FAILED');
    }

    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    constructor() public {
        // 由于本pair合约是由factory合约创建，所以deployer为factory合约地址
        // 将factory合约地址设置到状态变量factory中
        factory = msg.sender;
    }

    // 当factory创建该pair合约时会调用该方法
    function initialize(address _token0, address _token1) external {
        // 只能factory合约调用
        require(msg.sender == factory, 'UniswapV2: FORBIDDEN'); // sufficient check
        // 构成交易对的两种ERC20代币地址在factory合约中通过参数传入，并记录在对应的pair合约中
        token0 = _token0;
        token1 = _token1;
    }

    // update reserves and, on the first call per block, price accumulators
    // 更新pair的reserve，与传入的balance0和balance1对齐
    // 注：会在每个区块的第一笔调用该方法的交易中更新价格累加器
    function _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private {
        // 要求balance0和balance1都必须小于等于type(uint112).max，这是因为reverse0和reverse1都是uint112
        require(balance0 <= uint112(- 1) && balance1 <= uint112(- 1), 'UniswapV2: OVERFLOW');
        // blockTimestamp为当前区块时间戳对2^32取模，即取当前时间戳的低32位并转为uint32类型
        uint32 blockTimestamp = uint32(block.timestamp % 2 ** 32);
        // 计算blockTimestamp与状态变量blockTimestampLast之间的时间差（此处允许overflow）
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        // 如果传入的_reserve0和_reserve1不为0且本次调用_update()为本区块第一次调用
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // * never overflows, and + overflow is desired
            // price0的累计值自加(_reserve1<<112)/reserve0 * 距离上一次调用_update()的时间间隔
            // (_reserve1<<112)/reserve0为当前一个token0对token1的价格
            price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            // price1的累计值自加(_reserve0<<112)/reserve1 * 距离上一次调用_update()的时间间隔
            // (_reserve0<<112)/reserve1为当前一个token1对token0的价格
            price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }

        // 将balance0和balance1分别存储到全局变量reserve0和reverse1中
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        // 将blockTimestamp存储到状态变量中
        blockTimestampLast = blockTimestamp;
        // 抛出事件
        emit Sync(reserve0, reserve1);
    }

    // if fee is on, mint liquidity equivalent to 1/6th of the growth in sqrt(k)
    //
    // 如果收取平台收费，那么mint给平台的流动性为sqrt(k)增量的1/6，返回值为是否开启平台收费
    // 注：每一笔swap交易都会有千分之三的手续费，那么k值也会随着缓慢增加
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        // 从factory合约中获取fee的收款人地址
        address feeTo = IUniswapV2Factory(factory).feeTo();
        // feeTo如果为0地址表示不开启平台收费
        feeOn = feeTo != address(0);
        // 缓存状态变量kLast
        // 注：如果开启了平台收费，那么kLast为最近一次mint或burn后的reserve0*reserve1
        uint _kLast = kLast; // gas savings
        if (feeOn) {
            if (_kLast != 0) {
                // 如果开启平台收费且此时kLast不为0，即在开启平台收费时调用mint（非首次）或调用burn时进入
                // rootK为当前reserve0*reserve1的平方根
                uint rootK = Math.sqrt(uint(_reserve0).mul(_reserve1));
                // rootKLast为上次调用mint或burn后（开启平台收费时）的reserve0*reserve1的平方根
                uint rootKLast = Math.sqrt(_kLast);
                if (rootK > rootKLast) {
                    // 如果rootK>rootKLast
                    // 给平台的收费liquidity为：LP token的总发行量 * (rootK-rootKLast)/(5*rootK+rootKLast)
                    // 注： 上式通过以下方程推出：
                    //      LP token的总发行量/(LP token的总发行量+liquidity) = (1/6)*((rootK-rootKLast)/rootK)
                    // 其中
                    uint numerator = totalSupply.mul(rootK.sub(rootKLast));
                    uint denominator = rootK.mul(5).add(rootKLast);
                    uint liquidity = numerator / denominator;
                    // 如果liquidity>0，就给feeTo铸造对应数量的LP token作为平台收费
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (_kLast != 0) {
            // 如果不开启平台收费且kLast不为0时，直接将状态变量kLast置0
            // 注：该分支会在原先平台收费而后被改为平台不收费后，第一次调用mint()或burn()时进入
            kLast = 0;
        }
    }

    // this low-level function should be called from a contract which performs important safety checks
    // 铸币，返回值为to地址提供的流动性
    // 注：在Uniswap中，流动性用token表示，即LP token
    function mint(address to) external lock returns (uint liquidity) {
        // 获取当前的pair的reserve0和reserve1
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        // balance0为当前pair名下的token0余额
        uint balance0 = IERC20(token0).balanceOf(address(this));
        // balance为当前pair名下的token1余额
        uint balance1 = IERC20(token1).balanceOf(address(this));

        // mint()的调用发生在router合约向pair合约发送token之后
        // 因此此时的pair的reserve不等于pair的token余额，LP token就是由这两个差值计算得到，即amount0和amount1
        // amount0为当前pair名下的token0余额与reserve0之间的差值
        uint amount0 = balance0.sub(_reserve0);
        // amount1为当前pair名下的token1余额与reserve1之间的差值
        uint amount1 = balance1.sub(_reserve1);

        // 进行平台收费（如果开启了平台收费，将mint sqrt(k)增量的1/6的LP token给feeTo）
        bool feeOn = _mintFee(_reserve0, _reserve1);
        // 缓存状态变量totalSupply
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        if (_totalSupply == 0) {
            // 如果_totalSupply为0表示首次铸币（即第一笔添加流动性）
            // 首次铸币提供的流动性为sqrt(amount0*amount1) - 1000
            // 注：

            liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
            // 直接销毁1000个LP token，这样就永久地锁住了1000个LP token的流动性
            // 即使LP token大户将全部的LP token全burn掉，pair中仍会保证有1000 LP token的流动性
            _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
        } else {
            // 如果_totalSupply不为0表示非首次铸币
            // 获得流动性为(amount0/reserve0) * total supply 和 (amount1/reserve1) * total supply的最小值
            // 注： 所以添加者成本最低的注入流动性的方式就是按照reverse0与reverse1的比例添加
            liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1);
        }

        // 要求添加的流动性>0，否则revert
        require(liquidity > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED');
        // 为to地址铸造数量为liquidity的LP token
        _mint(to, liquidity);

        // 全局变量reserve0和reserve1对其balance0和balance1
        _update(balance0, balance1, _reserve0, _reserve1);
        // 如果开启了平台收费，kLast为更新后的reserve0*reserve1
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        // 抛出事件
        emit Mint(msg.sender, amount0, amount1);
    }

    // this low-level function should be called from a contract which performs important safety checks
    function burn(address to) external lock returns (uint amount0, uint amount1) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        address _token0 = token0;                                // gas savings
        address _token1 = token1;                                // gas savings
        uint balance0 = IERC20(_token0).balanceOf(address(this));
        uint balance1 = IERC20(_token1).balanceOf(address(this));
        uint liquidity = balanceOf[address(this)];

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        amount0 = liquidity.mul(balance0) / _totalSupply; // using balances ensures pro-rata distribution
        amount1 = liquidity.mul(balance1) / _totalSupply; // using balances ensures pro-rata distribution
        require(amount0 > 0 && amount1 > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED');
        _burn(address(this), liquidity);
        _safeTransfer(_token0, to, amount0);
        _safeTransfer(_token1, to, amount1);
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));

        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        emit Burn(msg.sender, amount0, amount1, to);
    }

    // this low-level function should be called from a contract which performs important safety checks
    // swap方法一般是被路由合约调用，
    // 参数：amount0Out：要swap出的token0的数量
    //      amount1Out：要swap出的token1的数量
    //      to：swap出的token的接收地址（一般是其他pair地址）
    //      data：用于执行闪电贷的参数
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external lock {
        // 要求amount0Out和amount1Out不能同时为0
        require(amount0Out > 0 || amount1Out > 0, 'UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT');
        // 获取当前的pair的reserve0和reserve1
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        // 要求本pair的reserve0和reserve1足以支付要swap出的token0和token1的数量
        require(amount0Out < _reserve0 && amount1Out < _reserve1, 'UniswapV2: INSUFFICIENT_LIQUIDITY');

        uint balance0;
        uint balance1;
        { // scope for _token{0,1}, avoids stack too deep errors
            // 使用大括号构造新的变量范围，避免编译时出现"stack too deep"错误
            // 缓存token0和token1的地址
            address _token0 = token0;
            address _token1 = token1;
            // 要求to地址不能是构成pair的token地址
            require(to != _token0 && to != _token1, 'UniswapV2: INVALID_TO');
            // 如果amount0Out>0，从pair地址向to地址转移amount0Out数量的token0
            if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens
            // 如果amount1Out>0，从pair地址向to地址转移amount1Out数量的token1
            if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens
            // 如果data参数不为0，执行to地址合约的uniswapV2Call方法（该方法为闪电贷的hook函数）
            if (data.length > 0) IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);
            // 获取此时pair合约名下的token0余额
            balance0 = IERC20(_token0).balanceOf(address(this));
            // 获取此时pair合约名下的token1余额
            balance1 = IERC20(_token1).balanceOf(address(this));
        }

        // amount0In为额外进入到pair合约名下的token0数量
        // _reserve0 - amount0Out为正常情况下本pair合约应当持有的token0数量
        // 如果balance0>_reserve0 - amount0Out，表示有额外的token0进入到
        // 本pair名下，amount0In = balance0 - (_reserve0 - amount0Out)
        // 否则amount0In=0
        uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        // amount1In为额外进入到pair合约名下的token1数量
        // _reserve1 - amount1Out为正常情况下本pair合约应当持有的token1数量
        // 如果balance1>_reserve1 - amount1Out，表示有额外的token1进入到
        // 本pair名下，amount1In = balance1 - (_reserve1 - amount1Out)
        // 否则amount1In=0
        uint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        // 确保amount0In或amount1In至少有一个大于0，否则revert
        // 注：如果是正常的swap，要换出token0，势必要输入token1
        require(amount0In > 0 || amount1In > 0, 'UniswapV2: INSUFFICIENT_INPUT_AMOUNT');
        { // scope for reserve{0,1}Adjusted, avoids stack too deep errors

            // 还需要确保swap后的reserve0*reserve1==k
            // 1000*balance0 - 3*amount0In
            uint balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
            // 1000*balance1 - 3*amount1In
            uint balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));
            // 确保下式成立：
            //      (1000*balance0 - 3*amount0In)*(1000*balance1 - 3*amount1In) >= _reserve0*_reserve1*1000*1000
            // ->   (balance0 - 0.003*amount0In)*(balance1 - 0.003*amount1In) >= _reserve0*_reserve1
            // 其中：0.003*amount0In或0.003*amount1In就是所谓的“千3”的交易手续费
            require(balance0Adjusted.mul(balance1Adjusted) >= uint(_reserve0).mul(_reserve1).mul(1000**2), 'UniswapV2: K');
        }

        // 全局变量reserve0和reserve1对其balance0和balance1
        _update(balance0, balance1, _reserve0, _reserve1);
        // 抛出事件
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    // force balances to match reserves
    // 强制向reserve对账，即将本合约名下token0和token1强制对齐reserve0和reserve1，多余的部分转移给to地址
    function skim(address to) external lock {
        // 将token0和token1缓存在memory中，后面多次使用节省gas
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        // 转移本合约名下的token0给to地址，数量为当前token0余额-reserve0
        _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this)).sub(reserve0));
        // 转移本合约名下的token1给to地址，数量为当前token1余额-reserve0
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)).sub(reserve1));
    }

    // force reserves to match balances
    // 强制向余额对账，即将本合约reserve0和reserve1强制对齐合约名下token0和token1
    function sync() external lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
    }
}
