// SPDX-License-Identifier: MIT
// Test cases for wyec.yaml (`semgrep --test contrib/semgrep/rules`). Not compiled: contrib/ is not a
// Foundry source directory.
pragma solidity ^0.8.24;

contract Cases {
    function origin() external view {
        // ruleid: wyec.auth.tx-origin
        require(tx.origin == owner);
        // ok: wyec.auth.tx-origin
        require(msg.sender == owner);
    }

    function calls(address t, bytes memory d) external {
        // ruleid: wyec.call.unchecked-low-level-call
        t.call(d);
        // ruleid: wyec.call.unchecked-low-level-call
        t.call{value: 1}(d);
        // ruleid: wyec.call.unchecked-low-level-call
        t.delegatecall(d);
        // ruleid: wyec.call.unchecked-low-level-call
        payable(t).send(1);
        // ok: wyec.call.unchecked-low-level-call
        (bool ok,) = t.call(d);
        require(ok);
        // ok: wyec.call.unchecked-low-level-call
        require(payable(t).send(1));
    }

    function recovers(bytes32 h, bytes calldata sig, uint8 v, bytes32 r, bytes32 s) external view {
        // ruleid: wyec.sig.recover-outside-eip712-domain
        ECDSA.recover(h, sig);
        // ruleid: wyec.sig.recover-outside-eip712-domain
        ECDSA.recover(MessageHashUtils.toEthSignedMessageHash(h), sig);
        // ruleid: wyec.sig.recover-outside-eip712-domain
        ecrecover(h, v, r, s);
        // ruleid: wyec.sig.recover-outside-eip712-domain
        ECDSA.recover(keccak256(abi.encode(MINT_TYPEHASH, h)), sig);
        // ok: wyec.sig.recover-outside-eip712-domain
        ECDSA.recover(_hashTypedDataV4(keccak256(abi.encode(MINT_TYPEHASH, h))), sig);
        // ok: wyec.sig.recover-outside-eip712-domain
        ECDSA.recover(mintDigest(h, 1, address(this)), sig);
        // ok: wyec.sig.recover-outside-eip712-domain
        ECDSA.recover(challengeDigest(h, 1), sig);
    }

    function _checkThreshold(bytes32 digest, bytes[] calldata sigs) internal view {
        // ok: wyec.sig.recover-outside-eip712-domain
        address a = ECDSA.recover(digest, sigs[0]);
    }

    function admin(bytes32 h, bytes[] calldata sigs) external {
        // ruleid: wyec.sig.threshold-outside-eip712-domain
        _checkThreshold(keccak256(abi.encode(SET_PAUSED_TYPEHASH, true)), sigs);
        // ok: wyec.sig.threshold-outside-eip712-domain
        _checkThreshold(_hashTypedDataV4(keccak256(abi.encode(SET_PAUSED_TYPEHASH, true))), sigs);
        // ok: wyec.sig.threshold-outside-eip712-domain
        _checkThreshold(mintDigest(h, 1, address(this)), sigs);
    }
}
