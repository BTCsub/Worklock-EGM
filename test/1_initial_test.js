const Migrations = artifacts.require("Migrations");

contract("Migrations", function(accounts) {
  var migrationInstance;

  it("initializes with two candidates", function() {
    return Migrations.deployed().then(function(instance) {
      return instance.owner();
    }).then(function(owner) {
      assert.equal(owner, accounts[0], "Owner should be 0th account");
    });
  });
});