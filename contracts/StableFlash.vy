# @version 0.2.16
"""
@title Stable Flash
@license MIT
@author stableflash.xyz
@notice
    Deposit tokens from the list of approved stablecoins to receive an almost 1-to-1 backed 
    ERC20 token that does have flash loan and swap capability.

    Tokens may be approved or disapproved by the admin.
    Once admin approves token, the specified token may be deposited into the contract and
    can be converted for other approved tokens with enough reserves, fee may be charged.
"""

from vyper.interfaces import ERC20

implements: ERC20


interface DetailedERC20:
    def decimals() -> uint256:
        view


event Transfer:
    sender: indexed(address)
    receiver: indexed(address)
    amount: uint256


event Approval:
    sender: indexed(address)
    receiver: indexed(address)
    amount: uint256


event StrategyDeposit:
    token: indexed(address)
    amount: uint256


event UpdateAdmin:
    admin: address


event UpdateFees:
    swapFee: uint256
    flashFee: uint256
    feeDivider: uint256


event UpdateMaxDeposits:
    maxDeposits: uint256


event SetLendingPool:
    lendingPool: address


event RemoveReserves:
    token: indexed(address)
    amount: uint256


interface IFlashMinter:
    # ERC-3156
    def onFlashLoan(
        sender: address,
        token: address,
        amount: uint256,
        fee: uint256,
        data: Bytes[1028],
    ):
        nonpayable


interface IStrategy:
    def deposit(token: address, amount: uint256):
        nonpayable

    def withdraw(token: address, amount: uint256, receiver: address):
        nonpayable


interface IOracle:
    def latestAnswer() -> uint256:
        view

    def decimals() -> uint256:
        view


struct UpcomingFees:
    swapFee: uint256
    flashFee: uint256
    feeDivider: uint256
    effectiveAt: uint256


struct Fees:
    swapFee: uint256
    flashFee: uint256
    feeDivider: uint256


struct Stablecoin:
    allowed: bool
    disabled: bool
    oracle: address


# Allowed stablecoins for the deposit
coins: public(HashMap[address, Stablecoin])
# Reserves of the stablecoin
reserves: public(HashMap[address, uint256])
# Fees
fees: public(Fees)
upcomingFees: public(UpcomingFees)
# Did user used withdraw or deposit at block?
interaction: HashMap[uint256, HashMap[address, bool]]
# User deposited token will be converted to self if deposits
# more than one from allowed tokens
deposited: public(HashMap[address, HashMap[address, uint256]])
# Maximum deposit allowed in contract
maxDeposits: public(uint256)

# Strategy
strategy: public(IStrategy)
# Lending supported for token
lendingAvailable: public(HashMap[address, bool])
# Reserves inside lending pool
underlyingReserves: public(HashMap[address, uint256])
# Earnings through the pool
earnings: public(HashMap[address, uint256])

# ERC20 details
name: public(String[64])
symbol: public(String[32])
balances: public(HashMap[address, uint256])
allowance: public(HashMap[address, HashMap[address, uint256]])
totalSupply: public(uint256)
decimals: public(uint256)
admin: public(address)

NAME: constant(String[64]) = "stableflash.xyz"
SYMBOL: constant(String[32]) = "STFL"
DECIMALS: constant(uint256) = 18
# Minimum deposit for a token for Aave
MIN_POOL_DEPOSIT: constant(uint256) = 10_000
ADMIN_WAIT: constant(uint256) = 86400


@external
def __init__(_supply: uint256):
    self.admin = msg.sender
    self.name = NAME
    self.symbol = SYMBOL
    supply: uint256 = _supply * 10 ** DECIMALS
    self.totalSupply = supply
    self.decimals = DECIMALS

    self.fees = Fees({swapFee: 0, flashFee: 0, feeDivider: 1})

    if supply > 0:
        self.balances[msg.sender] = supply
        log Transfer(ZERO_ADDRESS, msg.sender, supply)


@internal
def _mint(receiver: address, amount: uint256):
    self.balances[receiver] += amount
    self.totalSupply += amount

    log Transfer(ZERO_ADDRESS, receiver, amount)


@internal
def _burn(sender: address, amount: uint256):
    self.balances[sender] -= amount
    self.totalSupply -= amount

    log Transfer(sender, ZERO_ADDRESS, amount)


@internal
def _transfer(sender: address, receiver: address, amount: uint256):
    self.balances[sender] -= amount
    self.balances[receiver] += amount

    log Transfer(sender, receiver, amount)


@internal
def _scale(amount: uint256, _decimals: uint256, toScale: uint256 = 18) -> uint256:
    # Scale function aims to convert tokens where decimals are not enough
    # or higher than required. It is probably not higher than required.
    # DAO should consider this feature when listing a token.
    scaled: uint256 = amount
    if _decimals > toScale:
        scaled = amount / 10 ** (_decimals - toScale)
    if _decimals < toScale:
        scaled = amount / 10 ** (toScale - _decimals)

    return scaled


@internal
def _depositUnderlying(token: address, amount: uint256):
    self.strategy.deposit(token, amount)


@internal
def _availableReserves(token: address, amount: uint256) -> uint256[2]:
    depositAmount: uint256 = amount
    depositAmount -= min(self.reserves[token], amount)

    if depositAmount == 0:
        return [amount, 0]
    else:
        return [
            depositAmount,
            min(self.underlyingReserves[token], amount - depositAmount),
        ]


@external
@nonreentrant("swap")
def deposit(token: address, amount: uint256):
    """
    @notice
        Deposit token to receive amount in your balance

        If you deposit more than one token types, there will be discount
        on the withdrawal and you'll pay half of the fee with swap.

        If you deposit only one from the allowed tokens, there will be no
        fees on the withdrawal.
    @param token
        Token to deposit
    @param amount
        Amount to mint and transfer in token
    """
    assert self.coins[token].allowed
    # It it aims to prevent deposits & withdraws in the same block.
    # Flash minters can use swap() if they
    # want to convert their funds.
    assert not self.interaction[block.number][msg.sender]
    # Check if maximum deposits are exceeded
    assert (self.maxDeposits >= self.totalSupply) or (self.maxDeposits == 0)
    self.interaction[block.number][msg.sender] = True
    # Registering amount deposited by user so fee discount can be applied.
    self.deposited[msg.sender][token] += amount

    ERC20(token).transferFrom(msg.sender, self, amount)
    tokenDecimals: uint256 = DetailedERC20(token).decimals()
    # Scale decimals for compatibility
    scaled: uint256 = self._scale(amount, tokenDecimals)
    self.reserves[token] += scaled
    # Mint tokens for users
    self._mint(msg.sender, scaled)

    if ((MIN_POOL_DEPOSIT * 10 ** tokenDecimals) > self.reserves[token]) and (
        self.lendingAvailable[token]
    ):
        # Deposit assets to the strategy
        self._depositUnderlying(token, self.reserves[token])


@external
@nonreentrant("swap")
def withdraw(token: address, amount: uint256):
    """
    @notice
        Withdraw balance in token

        Withdraw fee may be charged if you are withdrawing
        different token than you deposited before.
    @param token
        Token to receive
    @param amount
        Amount to burn in balance and receive in token
    """
    assert self.coins[token].allowed
    assert not self.interaction[block.number][msg.sender]
    self.interaction[block.number][msg.sender] = True
    # Amount to withdraw, scaled (in withdraw token's decimals)
    toWithdraw: uint256 = self._scale(amount, 18, DetailedERC20(token).decimals())
    if not (self.deposited[msg.sender][token] >= amount):
        # In this case, user probably deposited more than one token for this reason,
        # there will be half of the swap fee charged from this operation
        toWithdraw -= (toWithdraw * self.fees.swapFee / self.fees.feeDivider) / 2
    else:
        # User didn't paid any fees because user deposited amount
        # that exceeds user's current withdrawal amount.
        self.deposited[msg.sender][token] -= toWithdraw

    self._burn(msg.sender, amount)

    # Withdraw path may be required where token is deposited into lending pool
    withdrawPath: uint256[2] = self._availableReserves(token, amount)

    if withdrawPath[1] == 0:
        # No need for withdrawing from strategy
        ERC20(token).transfer(msg.sender, toWithdraw)
    else:
        # Some or all of funds are required to be withdrawn
        # from Aave lending pool
        if withdrawPath[0] > 0:
            ERC20(token).transfer(msg.sender, withdrawPath[0])

        self.strategy.withdraw(token, withdrawPath[1], msg.sender)


@external
def emergencyWithdraw(token: address, amount: uint256):
    """
    @notice
        Allow users to withdraw a delisted token with zero fees

        There will be no fees on the withdrawal.
    @param token
        Token that is removed from contract
    @param amount
        Amount to withdraw
    """
    assert not self.coins[token].allowed
    self._burn(msg.sender, amount)
    self.reserves[token] -= amount
    ERC20(token).transfer(msg.sender, amount)


@external
def swap(tokenIn: address, tokenOut: address, amount: uint256):
    """
    @notice
        Swap tokenIn to tokenOut with no fees
    @param tokenIn
        Token you currently have
    @param tokenOut
        Token you want to have
    @param amount
        Amount you'll send & receive (stable swap)
    """
    assert self.coins[tokenIn].allowed and self.coins[tokenOut].allowed
    ERC20(tokenIn).transferFrom(msg.sender, self, amount)
    # Calculate the swap fee
    fee: uint256 = amount * self.fees.swapFee / self.fees.feeDivider
    # Transfers the fee to admin
    # TODO: Replace admin with DAO treasury
    self._mint(self.admin, fee)
    self.reserves[tokenIn] += amount
    # Amount - fee is sent to msg.sender
    self.reserves[tokenOut] -= amount - fee
    ERC20(tokenOut).transfer(msg.sender, amount - fee)


@external
def approve(receiver: address, amount: uint256) -> bool:
    """
    @notice
        Approve funds to receiver
    @param receiver
        Receiver that will be able to spend funds
    @param amount
        Amount of funds to allow receiver for usage
    """
    self.allowance[msg.sender][receiver] += amount
    log Approval(msg.sender, receiver, amount)
    return True


@external
def transfer(receiver: address, amount: uint256) -> bool:
    """
    @notice
        Transfer funds to receiver
    @param receiver
        Address that will receive funds
    @param amount
        Amount of funds to transfer
    """
    self._transfer(msg.sender, receiver, amount)
    return True


@external
def transferFrom(owner: address, receiver: address, amount: uint256) -> bool:
    """
    @notice
        Transfer from owner to receiver
    @param owner
        Address that holds funds
    @param receiver
        Address that will receive funds
    @param amount
        Amount of funds to transfer
    @dev
        You need to have allowance from receiver
    """
    self.allowance[owner][msg.sender] -= amount
    self._transfer(owner, receiver, amount)
    return True


@external
@view
def balanceOf(user: address) -> uint256:
    return self.balances[user]


@internal
def _flashFee(amount: uint256) -> uint256:
    return amount * self.fees.flashFee / self.fees.feeDivider


@external
@nonreentrant("lock")
def flashLoan(
    receiver: address, token: address, amount: uint256, data: Bytes[1028]
) -> bool:
    """
    @notice
        Flash mint tokens and return in same transaction
    @param receiver
        Address that executes onFlashLoan operation
    @param token
        Token to receive
    @param amount
        Amount of tokens to receive
    @param data
        Data to execute with flash loan operation
    """
    assert token == self
    fee: uint256 = self._flashFee(amount)

    self._mint(msg.sender, amount)
    IFlashMinter(receiver).onFlashLoan(msg.sender, token, amount, fee, data)
    self._burn(msg.sender, amount + fee)
    self._mint(self.admin, fee)

    return True


@external
def allowToken(token: address, _allowed: bool, _oracle: address):
    """
    @notice
        Allow token to be deposited
    @param token
        Token to change status
    @param _allowed
        Whether to allow deposits or not
    """
    assert msg.sender == self.admin
    self.coins[token].allowed = _allowed

    if _allowed:
        ERC20(token).approve(self.strategy.address, MAX_UINT256)
        self.coins[token].oracle = _oracle
    else:
        ERC20(token).approve(self.strategy.address, 0)
        self.coins[token].disabled = _allowed


@external
def updateFees(
    _swapFee: uint256,
    _flashFee: uint256,
    _feeDivider: uint256,
):
    """
    @notice
        Update fees for swap and flash mint
    @param _swapFee
        Swap fee
    @param _flashFee
        Flash mint fee
    @param _feeDivider
        Fee divider
    """
    assert msg.sender == self.admin
    self.upcomingFees = UpcomingFees(
        {
            swapFee: _swapFee,
            flashFee: _flashFee,
            feeDivider: _feeDivider,
            effectiveAt: block.timestamp + ADMIN_WAIT,
        }
    )

    log UpdateFees(_swapFee, _flashFee, _feeDivider)


@external
def acceptFees():
    """
    @notice
        Accept fees
    """
    assert block.timestamp > self.upcomingFees.effectiveAt

    self.fees = Fees(
        {
            swapFee: self.upcomingFees.swapFee,
            flashFee: self.upcomingFees.flashFee,
            feeDivider: self.upcomingFees.feeDivider,
        }
    )


@external
def setMaxDeposits(_maxDeposits: uint256):
    """
    @notice
        Set maximum allowed deposits on the contract

        If total supply already exceeds max deposits, deposits will be blocked.
        Set max deposits to 0 for no limits on deposits.
    @param _maxDeposits
        Max deposits allowed
    """
    assert msg.sender == self.admin
    self.maxDeposits = _maxDeposits


@external
def transferAdmin(_admin: address):
    """
    @notice
        Transfer admin
    @param _admin
        New admin
    """
    assert msg.sender == self.admin
    self.admin = _admin
    log UpdateAdmin(_admin)


@external
def setStrategy(_strategy: address):
    """
    @notice
        Set strategy
    @param _strategy
        Address of strategy
    """
    assert msg.sender == self.admin
    self.strategy = IStrategy(_strategy)
    log SetLendingPool(_strategy)


@external
def removeReserves(token: address, amount: uint256):
    """
    @notice
        Remove reserves
    @param token
        Token to remove reserves
    @param amount
        Amount to remove from underlying reserves
    """
    assert msg.sender == self.admin
    self.strategy.withdraw(token, amount, self)
    self.underlyingReserves[token] -= amount
    self.reserves[token] += amount
    log RemoveReserves(token, amount)


@external
def updateLending(token: address, enabled: bool):
    """
    @notice
        Update lending status, changes whether token is available for
        deposit & withdrawal to the lending pool.
    @param token
        Token to update lending status
    @param enabled
        If True, lending is allowed
    """
    assert msg.sender == self.admin
    self.lendingAvailable[token] = enabled


@external
def disableToken(token: address):
    """
    @notice
        Disable a allowed token if oracle price is lower than minimum
        allowed threshold
    @param token
        Token to disable
    """
    price: uint256 = IOracle(self.coins[token].oracle).latestAnswer()
    _decimals: uint256 = IOracle(self.coins[token].oracle).decimals()
    qty: uint256 = 10 ** _decimals

    minimum: uint256 = qty - (qty * 3 / 100)
    assert price <= minimum, "Not eligible for temporary disable"

    self.coins[token].allowed = False
    self.coins[token].disabled = True


@external
def enableToken(token: address):
    """
    @notice
        Enable a temporarily disabled stablecoin token if oracle is higher than
        minimum allowed threshold
    @param token
        Token to re-enable
    """
    assert self.coins[token].disabled, "Not already disabled"

    price: uint256 = IOracle(self.coins[token].oracle).latestAnswer()
    _decimals: uint256 = IOracle(self.coins[token].oracle).decimals()
    qty: uint256 = 10 ** _decimals

    minimum: uint256 = qty - (qty * 3 / 100)
    assert price >= minimum, "Not eligible for enabling"

    self.coins[token].allowed = True
    self.coins[token].disabled = False
