pragma solidity ^0.5.7;
pragma experimental ABIEncoderV2;

import "@studydefi/money-legos/dydx/contracts/DydxFlashloanBase.sol";
import "@studydefi/money-legos/dydx/contracts/ICallee.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import './Compound.sol';

contract YieldFarmer is ICallee, DydxFlashloanBase, Compound
 {
  enum Direction { Deposit, Withdraw } 
  struct Operation 
  {
    address token;
    address cToken;
    Direction direction;
    uint amountProvided;
    uint amountBorrowed;
  }
  address public owner;


  constructor(address _comptroller) Compound(_comptroller) public 
  {
    owner = msg.sender;
  }

  function openPosition
  (
    address _solo, 
    address _token, 
    address _cToken,
    uint _amountProvided, 
    uint _amountBorrowed
  ) external 
  {
    require(msg.sender == owner, 'only owner');
    IERC20(_token).transferFrom(msg.sender, address(this), _amountProvided);
    //2 wei is used to pay for flashloan
    _initiateFlashloan(_solo, _token, _cToken, Direction.Deposit, _amountProvided - 2, _amountBorrowed);
  }

  function closePosition
  (
    address _solo, 
    address _token, 
    address _cToken
  ) external 
  {
    require(msg.sender == owner, 'only owner');

    //2 wei is used to pay for flashloan
    IERC20(_token).transferFrom(msg.sender, address(this), 2);

    claimComp();

    // What we borrowed + interest
    uint borrowBalance = getBorrowBalance(_cToken);

    // We need a new flashloan to repay the borrowed money with + interest
    // If you lost more money than you earned, this call will be ignored and you can not close your position unless you put some more money on this contract
    _initiateFlashloan(_solo, _token, _cToken, Direction.Withdraw, 0, borrowBalance);

    // Get the money you earned for the liquidity you provided
    address compAddress = getCompAddress();
    IERC20 comp = IERC20(compAddress);
    uint compBalance = comp.balanceOf(address(this));
    comp.transfer(msg.sender, compBalance);

    // Get the money you earned for interest on your lended out money
    IERC20 token = IERC20(_token);
    uint tokenBalance = token.balanceOf(address(this));
    
    token.transfer(msg.sender, tokenBalance);
  }

  function callFunction
  (
    address sender,
    Account.Info memory account,
    bytes memory data
  ) public 
  {
    Operation memory operation = abi.decode(data, (Operation));

    if(operation.direction == Direction.Deposit) 
    {
      // Lend out the flashloan money
      supply(operation.cToken, operation.amountProvided + operation.amountBorrowed);

      enterMarket(operation.cToken);

      // Borrow new money to pay back flashloan with
      borrow(operation.cToken, operation.amountBorrowed);
    } 
    else 
    {
      // Repay borrowed new money
      repayBorrow(operation.cToken, operation.amountBorrowed);
      uint cTokenBalance = getcTokenBalance(operation.cToken);

      // Get lended out money back
      redeem(operation.cToken, cTokenBalance);
    }
  }

  function _initiateFlashloan
  (
    address _solo, 
    address _token, 
    address _cToken, 
    Direction _direction,
    uint _amountProvided, 
    uint _amountBorrowed
  )
    internal
  {
    ISoloMargin solo = ISoloMargin(_solo);

    // Get marketId from token address
    uint256 marketId = _getMarketIdFromTokenAddress(_solo, _token);

    // Calculate repay amount (_amount + (2 wei))
    // Approve transfer from
    uint256 repayAmount = _getRepaymentAmountInternal(_amountBorrowed);
    IERC20(_token).approve(_solo, repayAmount);

    // 1. Withdraw $
    // 2. Call callFunction(...)
    // 3. Deposit back $
    Actions.ActionArgs[] memory operations = new Actions.ActionArgs[](3);

    operations[0] = _getWithdrawAction(marketId, _amountBorrowed);
    operations[1] = _getCallAction(
        // Encode MyCustomData for callFunction
        abi.encode(Operation({
          token: _token, 
          cToken: _cToken, 
          direction: _direction,
          amountProvided: _amountProvided, 
          amountBorrowed: _amountBorrowed
        }))
    );
    operations[2] = _getDepositAction(marketId, repayAmount);

    Account.Info[] memory accountInfos = new Account.Info[](1);
    accountInfos[0] = _getAccountInfo();

    solo.operate(accountInfos, operations);
  }
}