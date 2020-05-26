var BTCsubToken = artifacts.require("BTCsubToken");
// var Slashing = artifacts.require("Slashing");
var StakingEscrow = artifacts.require("StakingEscrow");
var WorkLock = artifacts.require("WorkLock");

module.exports = async function(deployer) {
	/**
	* @notice deploying BTCsubToken contract first
	**/
	await deployer.deploy(BTCsubToken, 1000000);

	/**
	* @notice deploying the Slashing contract
	**/
	// await deployer.deploy(Slashing);

	// Slashing is to be inherited by StakingEscrow contract, therefore creating a link
	// await deployer.link(Slashing, StakingEscrow);

	/**
	* @notice deploying the StakingEscrow contract
	**/

	/**
	* uint32 _hoursPerPeriod = 10,
    * uint256 _issuanceDecayCoefficient = 2425,
    * uint256 _lockDurationCoefficient1 = 365 (default),
    * uint256 _lockDurationCoefficient2 = 730 (default),
    * uint16 _maximumRewardedPeriods = 365 (default),
    * uint256 _firstPhaseTotalSupply = 50000,
    * uint256 _firstPhaseMaxIssuance = 200,
    * uint16 _minLockedPeriods = 20,
    * uint256 _minAllowableLockedTokens = 500,
    * uint256 _maxAllowableLockedTokens = 2000,
    * uint16 _minWorkerPeriods = 20,
    * bool _isTestContract = true
    **/
	await deployer.deploy(StakingEscrow, BTCsubToken.address, 1, 2425, 365, 730, 365, 50000, 200, 20, 500, 2000, 20, true);

	/**
	* @notice deploying the WorkLock contract
	**/

	/**
	* uint256 _startBidDate,
    * uint256 _endBidDate,
    * uint256 _endCancellationDate,
    * uint256 _boostingRefund = 1,
    * uint16 _stakingPeriods = 20,
    * uint256 _minAllowedBid = 4
	**/
	let date = (new Date()).getTime();
	let startDate = date / 1000;
	let cancellationDate = startDate + 250;
	let endDate = startDate + 1000;
	await deployer.deploy(WorkLock, BTCsubToken.address, StakingEscrow.address, startDate, endDate, cancellationDate, 1, 20, 4);

};