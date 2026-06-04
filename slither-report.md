**THIS CHECKLIST IS NOT COMPLETE**. Use `--show-ignored-findings` to show all the results.
Summary
 - [incorrect-equality](#incorrect-equality) (1 results) (Medium)
 - [reentrancy-events](#reentrancy-events) (1 results) (Low)
 - [timestamp](#timestamp) (2 results) (Low)
 - [pragma](#pragma) (1 results) (Informational)
 - [naming-convention](#naming-convention) (5 results) (Informational)
## incorrect-equality
Impact: Medium
Confidence: High
 - [ ] ID-0
[BLOKCAmbassadorAccount.withdrawTokensAll()](.src/contracts/BLOKCAmbassadorAccount.sol#L337-L343) uses a dangerous strict equality:
	- [currentBalance == 0](.src/contracts/BLOKCAmbassadorAccount.sol#L339)

.src/contracts/BLOKCAmbassadorAccount.sol#L337-L343


## reentrancy-events
Impact: Low
Confidence: Medium
 - [ ] ID-1
Reentrancy in [BLOKCAmbassadorFactory._createAmbassadorAccount(address)](.src/contracts/factory/BLOKCAmbassadorFactory.sol#L214-L228):
	External calls:
	- [BLOKCAmbassadorAccount(ambassadorAccount).initialize(ambassador,token,unlockTimestamp)](.src/contracts/factory/BLOKCAmbassadorFactory.sol#L225)
	Event emitted after the call(s):
	- [AmbassadorAccountCreated(ambassador,ambassadorAccount)](.src/contracts/factory/BLOKCAmbassadorFactory.sol#L226)

.src/contracts/factory/BLOKCAmbassadorFactory.sol#L214-L228


## timestamp
Impact: Low
Confidence: Medium
 - [ ] ID-2
[BLOKCAmbassadorAccount.isUnlocked()](.src/contracts/BLOKCAmbassadorAccount.sol#L368-L370) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp >= unlockTimestamp](.src/contracts/BLOKCAmbassadorAccount.sol#L369)

.src/contracts/BLOKCAmbassadorAccount.sol#L368-L370


 - [ ] ID-3
[BLOKCAmbassadorAccount.timeUntilUnlock()](.src/contracts/BLOKCAmbassadorAccount.sol#L375-L377) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp >= unlockTimestamp](.src/contracts/BLOKCAmbassadorAccount.sol#L376)

.src/contracts/BLOKCAmbassadorAccount.sol#L375-L377


## pragma
Impact: Informational
Confidence: High
 - [ ] ID-4
5 different versions of Solidity are used:
	- Version constraint >=0.8.4 is used by:
		-[>=0.8.4](.lib/openzeppelin-contracts/contracts/governance/utils/IVotes.sol#L4)
	- Version constraint >=0.6.2 is used by:
		-[>=0.6.2](.lib/openzeppelin-contracts/contracts/interfaces/IERC1363.sol#L4)
	- Version constraint >=0.4.16 is used by:
		-[>=0.4.16](.lib/openzeppelin-contracts/contracts/interfaces/IERC165.sol#L4)
		-[>=0.4.16](.lib/openzeppelin-contracts/contracts/interfaces/IERC20.sol#L4)
		-[>=0.4.16](.lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol#L4)
		-[>=0.4.16](.lib/openzeppelin-contracts/contracts/utils/introspection/IERC165.sol#L4)
	- Version constraint ^0.8.20 is used by:
		-[^0.8.20](.lib/openzeppelin-contracts/contracts/proxy/Clones.sol#L4)
		-[^0.8.20](.lib/openzeppelin-contracts/contracts/proxy/utils/Initializable.sol#L4)
		-[^0.8.20](.lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol#L4)
		-[^0.8.20](.lib/openzeppelin-contracts/contracts/utils/Create2.sol#L4)
		-[^0.8.20](.lib/openzeppelin-contracts/contracts/utils/Errors.sol#L4)
		-[^0.8.20](.lib/openzeppelin-contracts/contracts/utils/LowLevelCall.sol#L4)
	- Version constraint ^0.8.24 is used by:
		-[^0.8.24](.src/contracts/BLOKCAmbassadorAccount.sol#L2)
		-[^0.8.24](.src/contracts/factory/BLOKCAmbassadorFactory.sol#L2)

.lib/openzeppelin-contracts/contracts/governance/utils/IVotes.sol#L4


## naming-convention
Impact: Informational
Confidence: High
 - [ ] ID-5
Parameter [BLOKCAmbassadorAccount.recoverERC20(address,address,uint256).ERC20token](.src/contracts/BLOKCAmbassadorAccount.sol#L280) is not in mixedCase

.src/contracts/BLOKCAmbassadorAccount.sol#L280


 - [ ] ID-6
Parameter [BLOKCAmbassadorAccount.initialize(address,address,uint64)._unlockTimestamp](.src/contracts/BLOKCAmbassadorAccount.sol#L179) is not in mixedCase

.src/contracts/BLOKCAmbassadorAccount.sol#L179


 - [ ] ID-7
Parameter [BLOKCAmbassadorAccount.initialize(address,address,uint64)._ambassador](.src/contracts/BLOKCAmbassadorAccount.sol#L179) is not in mixedCase

.src/contracts/BLOKCAmbassadorAccount.sol#L179


 - [ ] ID-8
Parameter [BLOKCAmbassadorAccount.reDelegate(address)._to](.src/contracts/BLOKCAmbassadorAccount.sol#L261) is not in mixedCase

.src/contracts/BLOKCAmbassadorAccount.sol#L261


 - [ ] ID-9
Parameter [BLOKCAmbassadorAccount.initialize(address,address,uint64)._token](.src/contracts/BLOKCAmbassadorAccount.sol#L179) is not in mixedCase

.src/contracts/BLOKCAmbassadorAccount.sol#L179


