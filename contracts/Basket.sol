/*

  Copyright 2018 CoinAlpha, Inc.
  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

  http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.

*/

pragma solidity ^0.4.22;

import "./zeppelin/SafeMath.sol";
import "./zeppelin/StandardToken.sol";
import "./zeppelin/ERC20.sol";

import "./BasketFactory.sol";
import "./BasketRegistry.sol";
import "./BasketSwap.sol";

/// @title Basket -- Basket contract for bundling and debundling tokens
/// @author CoinAlpha, Inc. <contact@coinalpha.com>
contract Basket is StandardToken {
  using SafeMath for uint;

  // Constants set at contract inception
  string                  public name;
  string                  public symbol;
  address[]               public tokens;
  uint[]                  public weights;

  address                 public arranger;
  address                 public arrangerFeeRecipient;
  uint                    public arrangerFee;

  address                 public previousBasketSwap;
  address                 public nextBasketSwap;

  // Modules
  IBasketRegistry         public basketRegistry;

  // Modifiers
  modifier onlyArranger {
    require(msg.sender == arranger, "Only the Arranger can call this function");
    _;
  }

  // Events
  event LogDepositAndBundle(address indexed holder, uint indexed quantity);
  event LogDebundleAndWithdraw(address indexed holder, uint indexed quantity);
  event LogArrangerFeeRecipientChange(address indexed newRecipient);
  event LogArrangerFeeChange(uint indexed newFee);
  event LogRebalance(address indexed holder, uint indexed quantity);
  event LogSetPreviousBasketSwap(address indexed previousBasketSwap);
  event LogSetNextBasketSwap(address indexed nextBasketSwap);

  /// @dev Basket constructor
  /// @param  _name                                Token name
  /// @param  _symbol                              Token symbol
  /// @param  _tokens                              Array of ERC20 token addresses
  /// @param  _weights                             Array of ERC20 token quantities
  /// @param  _basketRegistryAddress               Address of basket registry
  /// @param  _arranger                            Address of arranger
  /// @param  _arrangerFeeRecipient                Address to send arranger fees
  /// @param  _arrangerFee                         Amount of fee in ETH for every basket minted
  constructor(
    string    _name,
    string    _symbol,
    address[] _tokens,
    uint[]    _weights,
    address   _basketRegistryAddress,
    address   _arranger,
    address   _arrangerFeeRecipient,
    uint      _arrangerFee                         // Amount of ETH charged per basket minted
  ) public {
    require(_tokens.length > 0 && _tokens.length == _weights.length, "Constructor: invalid number of tokens and weights");

    name = _name;
    symbol = _symbol;
    tokens = _tokens;
    weights = _weights;

    basketRegistry = IBasketRegistry(_basketRegistryAddress);

    arranger = _arranger;
    arrangerFeeRecipient = _arrangerFeeRecipient;
    arrangerFee = _arrangerFee;
  }

  /// @dev Combined deposit of all component tokens (not yet deposited) and bundle
  /// @param  _quantity                            Quantity of basket tokens to mint
  /// @return success                              Operation successful
  function depositAndBundle(uint _quantity) public payable returns (bool success) {
    for (uint i = 0; i < tokens.length; i++) {
      address t = tokens[i];
      uint w = weights[i];
      assert(ERC20(t).transferFrom(msg.sender, this, w.mul(_quantity).div(10 ** 18)));
    }

    // charging market makers a fee for every new basket minted
    // skip fees if tokens are minted through swaps
    if (previousBasketSwap != msg.sender && arrangerFee > 0) {
      require(msg.value >= arrangerFee.mul(_quantity).div(10 ** 18), "Insufficient ETH for arranger fee to bundle");
      arrangerFeeRecipient.transfer(msg.value);
    } else {
      // prevent transfers of unnecessary ether into the contract
      require(msg.value == 0);
    }

    balances[msg.sender] = balances[msg.sender].add(_quantity);
    totalSupply_ = totalSupply_.add(_quantity);

    basketRegistry.incrementBasketsMinted(_quantity, msg.sender);
    emit LogDepositAndBundle(msg.sender, _quantity);
    return true;
  }


  /// @dev Convert basketTokens back to original tokens and transfer to requester
  /// @param  _quantity                            Quantity of basket tokens to convert back to original tokens
  /// @return success                              Operation successful
  function debundleAndWithdraw(uint _quantity) public returns (bool success) {
    assert(debundle(_quantity, msg.sender, msg.sender));
    emit LogDebundleAndWithdraw(msg.sender, _quantity);
    return true;
  }

  /// @dev Convert basketTokens back to original tokens and transfer to swap contract and initiate swap
  /// @param  _quantity                            Quantity of basket tokens to swap
  /// @return success                              Operation successful
  function rebalance(uint _quantity) public returns (bool success) {
    assert(debundle(_quantity, msg.sender, previousBasketSwap));
    assert(BasketSwap(nextBasketSwap).swap(msg.sender, _quantity));
    emit LogRebalance(msg.sender, _quantity);
    return true;
  }

  /// @dev Convert basketTokens back to original tokens and transfer to swap contract and initiate swap
  /// @param  _quantity                            Quantity of basket tokens to swap
  /// @param  _sender                              Address of transaction sender
  /// @param  _recipient                           Address of token recipient
  /// @return success                              Operation successful
  function debundle(uint _quantity, address _sender, address _recipient) internal returns (bool success) {
    require(balances[_sender] >= _quantity, "Insufficient basket balance to debundle");
    // decrease holder balance and total supply by _quantity
    balances[_sender] = balances[_sender].sub(_quantity);
    totalSupply_ = totalSupply_.sub(_quantity);

    // increase balance of each of the tokens by their weights
    for (uint i = 0; i < tokens.length; i++) {
      address t = tokens[i];
      uint w = weights[i];
      ERC20(t).transfer(_recipient, w.mul(_quantity).div(10 ** 18));
    }

    basketRegistry.incrementBasketsBurned(_quantity, _sender);
    return true;
  }

  /// @dev Change recipient of arranger fees
  /// @param  _newRecipient                        New fee recipient
  /// @return success                              Operation successful
  function changeArrangerFeeRecipient(address _newRecipient) public onlyArranger returns (bool success) {
    arrangerFeeRecipient = _newRecipient;
    emit LogArrangerFeeRecipientChange(arrangerFeeRecipient);
    return true;
  }

  /// @dev Change amount of fee charged for every basket minted
  /// @param  _newFee                              New fee amount
  /// @return success                              Operation successful
  function changeArrangerFee(uint _newFee) public onlyArranger returns (bool success) {
    arrangerFee = _newFee;
    emit LogArrangerFeeChange(arrangerFee);
    return true;
  }

  /// @dev Change permitted previousBasketSwap for rebalance
  /// @param  _newPreviousBasketSwap               New premitted previous basketSwap
  /// @return success                              Operation successful
  function setPreviousBasketSwap(address _newPreviousBasketSwap) public onlyArranger returns (bool success) {
    previousBasketSwap = _newPreviousBasketSwap;
    emit LogSetPreviousBasketSwap(previousBasketSwap);
    return true;
  }

  /// @dev Change permitted nextBasketSwap for rebalance
  /// @param  _newNextBasketSwap                   New premitted next basketSwap
  /// @return success                              Operation successful
  function setNextBasketSwap(address _newNextBasketSwap) public onlyArranger returns (bool success) {
    nextBasketSwap = _newNextBasketSwap;
    emit LogSetNextBasketSwap(nextBasketSwap);
    return true;
  }


  /// @dev Fallback to reject any ether sent to contract
  function () public payable { revert("Baskets do not accept ETH transfers"); }

}
