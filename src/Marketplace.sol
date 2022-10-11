// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "./interfaces/IMarketplace.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {SignatureVerifier} from "./SignatureVerifier.sol";
import {EIP_712_DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH} from "./Constants.sol";

contract Marketplace is IMarketplace, Ownable, SignatureVerifier {
    using Orders for Orders.Order;
    using ERC165Checker for address;

    bytes4 public constant IID_IERC1155 = type(IERC1155).interfaceId;
    bytes4 public constant IID_IERC721 = type(IERC721).interfaceId;

    // keeps track of a user's latest nonce
    mapping(address => uint256) public userCurrentOrderNonce; 
    // keeps track of a user's min active nonce
    mapping(address => uint256) public userMinOrderNonce; 
    // keeps track of random nonces that have been cancelled
    mapping(address => mapping(uint256 => bool)) public _isUserOrderNonceExecutedOrCancelled; 

    event CancelAllOrders(address indexed user, uint256 newMinNonce);
    event CancelMultipleOrders(address indexed user, uint256[] orderNonces);
    event OrderFulfilled(
        address from, address to, address collection, uint256 tokenId, uint256 amount, address currency, uint256 price
    );

    error InvalidNonce();
    error OrderExpired();
    error OrderNotActive();
    error InvalidTokenAmount();

    constructor() {}

    // ============ Order methods ==================

    /**
     * @notice Fulfills an order stored off chain. Call must be made by
     * either the buyer or the seller depending if the order is an ask or bid.
     * Order must also be signed according to the EIP-712 standard and order.signer
     * must be the address of the order.signature signer.
     * @param order The order to be fulfilled
     */
    function fulfillOrder(Orders.Order calldata order) external {
        _validateOrder(order);

        // Update signer order status to true (prevents replay)
        _isUserOrderNonceExecutedOrCancelled[order.signer][order.nonce] = true;

        _fulfillOrder(order);
    }

    function _validateOrder(Orders.Order calldata order) internal view {
        bytes32 DOMAIN_SEPARATOR = _deriveDomainSeparator();
        bytes32 digest = _deriveEIP712Digest(DOMAIN_SEPARATOR, order.hash());
        _assertValidSignature(order.signer, digest, order.signature);

        if (order.startTime > block.timestamp) {
            revert OrderNotActive();
        }
        if (order.endTime < block.timestamp) {
            revert OrderExpired();
        }

        // Nonce is valid verification
        if (
            (_isUserOrderNonceExecutedOrCancelled[order.signer][order.nonce])
                || (order.nonce < userMinOrderNonce[order.signer])
        ) {
            revert InvalidNonce();
        }
    }

    function _deriveDomainSeparator() public view returns (bytes32) {
        return keccak256(abi.encode(EIP_712_DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this)));
    }

    function _fulfillOrder(Orders.Order calldata order) internal {
        address seller = order.isAsk ? order.signer : msg.sender;
        address buyer = order.isAsk ? msg.sender : order.signer;

        _transferFeesAndFunds(buyer, seller, order.currency, order.price);
        _transferNonFungibleToken(order.collection, seller, buyer, order.tokenId, order.amount);

        emit OrderFulfilled(seller, buyer, order.collection, order.tokenId, order.amount, order.currency, order.price);
    }

    /**
     * @notice Cancel all pending orders for a sender
     * @param minNonce minimum user nonce
     */
    function cancelAllOrdersForSender(uint256 minNonce) external {
        require(minNonce > userMinOrderNonce[msg.sender], "Cancel: Order nonce lower than current");
        require(minNonce < userMinOrderNonce[msg.sender] + 500000, "Cancel: Cannot cancel more orders");
        userMinOrderNonce[msg.sender] = minNonce;

        emit CancelAllOrders(msg.sender, minNonce);
    }

    /**
     * @notice Cancel maker orders
     * @param orderNonces array of order nonces
     */
    function cancelMultipleOrders(uint256[] calldata orderNonces) external {
        require(orderNonces.length > 0, "Cancel: Cannot be empty");

        for (uint256 i = 0; i < orderNonces.length; i++) {
            require(orderNonces[i] >= userMinOrderNonce[msg.sender], "Cancel: Order nonce lower than current");
            _isUserOrderNonceExecutedOrCancelled[msg.sender][orderNonces[i]] = true;
        }

        emit CancelMultipleOrders(msg.sender, orderNonces);
    }

    // ============ Transfer methods ==============

    /**
     * @notice Transfer NFTs
     * @param collection address of the token collection
     * @param from address of the sender
     * @param to address of the recipient
     * @param tokenId tokenId
     * @param amount amount of tokens
     */
    function _transferNonFungibleToken(address collection, address from, address to, uint256 tokenId, uint256 amount)
        internal
    {
        if (collection.supportsInterface(IID_IERC721)) {
            IERC721(collection).safeTransferFrom(from, to, tokenId);
        } else if (collection.supportsInterface(IID_IERC1155)) {
            IERC1155(collection).safeTransferFrom(from, to, tokenId, amount, "");
        } else {
            revert InvalidTokenAmount();
        }
    }

    /**
     * @notice Transfer fees and funds to royalty recipient, protocol, and seller
     * @param from sender of the funds
     * @param to seller's recipient
     * @param amount amount being transferred (in currency)
     */
    function _transferFeesAndFunds(address from, address to, address currency, uint256 amount) internal {
        IERC20(currency).transferFrom(from, to, amount);
    }

    // ============ View methods ==================

    function getCurrentNonceForAddress(address add) public view returns (uint256) {
        return userCurrentOrderNonce[add];
    }

    function getIsUserOrderNonceExecutedOrCanceled(address add, uint256 nonce) public view returns (bool) {
        return _isUserOrderNonceExecutedOrCancelled[add][nonce];
    }

    function getCurrentMinNonceForAddress(address add) public view returns (uint256) {
        return userMinOrderNonce[add];
    }

    function incrementCurrentNonceForAddress(address add) public onlyOwner {
        userCurrentOrderNonce[add]++;
    }
}

/*
 * 88888888ba  88      a8P  88
 * 88      "8b 88    ,88'   88
 * 88      ,8P 88  ,88"     88
 * 88aaaaaa8P' 88,d88'      88
 * 88""""88'   8888"88,     88
 * 88    `8b   88P   Y8b    88
 * 88     `8b  88     "88,  88
 * 88      `8b 88       Y8b 88888888888
 *
 * Marketplace: Marketplace.sol
 *
 * MIT License
 * ===========
 *
 * Copyright (c) 2022 Rumble League Studios Inc.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 */
