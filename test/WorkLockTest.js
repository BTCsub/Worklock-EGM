const WorkLock = artifacts.require('WorkLock');

let deployedSuccessfully;

contract('WorkLock', function() {
	let worklock = null;
	before(async function() {
		this.timeout(40000);
		worklock = await WorkLock.deployed();
	});

	// Test 1
	// To check if WorkLock.sol is deployed or not.
	it("Contract is deployed successfully", function() {
    	return WorkLock.deployed().then(function (instance) {
      	deployedSuccessfully = instance;
      	assert(deployedSuccessfully !== undefined, 'WorkLock contract should be defined');
    	});
  	});

  	// Test 2
  	// To test that the uplinks get the bonus.
	it('Should create a new user', async() => {
		// creating an array of uplinks
		const uplink = [account[0], account[1], account[2], account[3]];
		const bonusAdded = await worklock.addBonus(uplink);
		assert.equal(bonusAdded.executed, true);
	});
});