# @version 0.2.15
from vyper.interfaces import ERC20


@external
def onFlashLoan(
    sender: address, token: address, amount: uint256, fee: uint256, data: Bytes[1028]
):
    ERC20(token).transfer(tx.origin, amount)
