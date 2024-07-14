import HashMap "mo:base/HashMap";
import Principal "mo:base/Principal";
import Debug "mo:base/Debug";
import Iter "mo:base/Iter";
import Buffer "mo:base/Buffer";
import Array "mo:base/Array";
import Text "mo:base/Text";
import Nat "mo:base/Nat";
import Int "mo:base/Int";
import Blob "mo:base/Blob";
import Cycles "mo:base/ExperimentalCycles";
import Common "../common";
import RepositoryPartition "../repository_backend/RepositoryPartition";
import indirect_caller "canister:indirect_caller";

/// TODO: Methods to query for all installed packages.
shared({caller}) actor class PackageManager() = this {
    stable var _ownersSave: [(Principal, ())] = [];
    var owners: HashMap.HashMap<Principal, ()> =
        HashMap.fromIter([(caller, ())].vals(), 1, Principal.equal, Principal.hash);

    stable var nextInstallationId: Nat = 0;

    stable var _installedPackagesSave: [(Common.InstallationId, Common.InstalledPackageInfo)] = [];
    var installedPackages: HashMap.HashMap<Common.InstallationId, Common.InstalledPackageInfo> =
        HashMap.fromIter([].vals(), 0, Nat.equal, Int.hash);

    stable var _installedPackagesByNameSave: [(Common.PackageName, [Common.InstallationId])] = [];
    var installedPackagesByName: HashMap.HashMap<Common.PackageName, [Common.InstallationId]> =
        HashMap.fromIter([].vals(), 0, Text.equal, Text.hash);

    stable var _halfInstalledPackagesSave: [(Common.InstallationId, {
        shouldHaveModules: Nat;
        name: Common.PackageName;
        version: Common.Version;
        modules: [Principal];
    })] = [];
    var halfInstalledPackages: HashMap.HashMap<Common.InstallationId, Common.HalfInstalledPackageInfo> =
        HashMap.fromIter([].vals(), 0, Nat.equal, Int.hash);

    stable var repositories: [{canister: Principal; name: Text}] = []; // TODO: a more suitable type like `HashMap` or at least `Buffer`?

    func onlyOwner(caller: Principal) {
        if (owners.get(caller) == null) {
            Debug.trap("not the owner");
        }
    };

    type canister_settings = {
        freezing_threshold : ?Nat;
        controllers : ?[Principal];
        memory_allocation : ?Nat;
        compute_allocation : ?Nat;
    };

    type canister_id = Principal;
    type wasm_module = Blob;

    type CanisterCreator = actor {
        create_canister : shared { settings : ?canister_settings } -> async {
            canister_id : canister_id;
        };
        install_code : shared {
            arg : [Nat8];
            wasm_module : wasm_module;
            mode : { #reinstall; #upgrade; #install };
            canister_id : canister_id;
        } -> async ();
    };

    /// We don't install dependencies here (see `specs.odt`).
    public shared({caller}) func installPackage({
        part: Common.RepositoryPartitionRO;
        packageName: Common.PackageName;
        version: Common.Version;
    })
        : async Common.InstallationId
    {
        onlyOwner(caller);

        let package = await part.getPackage(packageName, version);
        let #real realPackage = package.specific else {
            Debug.trap("trying to directly install a virtual package");
        };
        let numPackages = Array.size(realPackage.wasms);

        let installationId = nextInstallationId;
        nextInstallationId += 1;

        let ourHalfInstalled: Common.HalfInstalledPackageInfo = {
            shouldHaveModules = numPackages;
            // id = installationId;
            name = package.base.name;
            version = package.base.version;
            modules = Buffer.Buffer<Principal>(numPackages);
            // packageDescriptionIn = part;
            package;
        };
        halfInstalledPackages.put(installationId, ourHalfInstalled);

        await* _finishInstallPackage({
            installationId;
            ourHalfInstalled;
            realPackage;
        });

        installationId;
    };

    /// Finish installation of a half-installed package.
    public shared({caller}) func finishInstallPackage({installationId: Nat}): async () {
        onlyOwner(caller);
        
        let ?ourHalfInstalled = halfInstalledPackages.get(installationId) else {
            Debug.trap("package installation has not been started");
        };
        let #real realPackage = ourHalfInstalled.package.specific else {
            Debug.trap("trying to directly install a virtual package");
        };
        await* _finishInstallPackage({
            installationId;
            ourHalfInstalled;
            realPackage;
        });
    };

    private func _finishInstallPackage({
        installationId: Nat;
        ourHalfInstalled: Common.HalfInstalledPackageInfo;
        realPackage: Common.RealPackageInfo;
    }): async* () {
        let IC: CanisterCreator = actor("aaaaa-aa");

        // let canisters = Buffer.Buffer<Principal>(numPackages);
        // TODO: Don't wait for creation of a previous canister to create the next one.
        for (wasmModuleLocation in realPackage.wasms.vals()) {
            // TODO: cycles (and monetization)
            Cycles.add<system>(10_000_000_000_000);
            let {canister_id} = await IC.create_canister({
                settings = ?{
                    freezing_threshold = null; // FIXME: 30 days may be not enough, make configurable.
                    controllers = null; // We are the controller.
                    compute_allocation = null; // TODO
                    memory_allocation = null; // TODO (a low priority task)
                }
            });
            let wasmModuleSourcePartition: RepositoryPartition.RepositoryPartition =
                actor(Principal.toText(wasmModuleLocation.0));
            let ?(#blob wasm_module) =
                await wasmModuleSourcePartition.getAttribute(wasmModuleLocation.1, "w")
            else {
                Debug.trap("package WASM code is not available");
            };
            let installArg = to_candid({
                user = caller;
                previousCanisters = Buffer.toArray(ourHalfInstalled.modules);
                packageManager = this;
            });
            await IC.install_code({
                arg = Blob.toArray(installArg);
                wasm_module;
                mode = #install;
                canister_id;
            });
            // canisters.add(canister_id);
            ourHalfInstalled.modules.add(canister_id);
        };
        indirect_caller.callIgnoringMissing(
            Iter.toArray(Iter.map<Nat, {canister: Principal; name: Text; data: Blob}>(
                Buffer.toArray(ourHalfInstalled.modules).keys(), // TODO: inefficient?
                func (i: Nat) = {
                    canister = ourHalfInstalled.modules.get(i);
                    name = Common.NamespacePrefix # "init";
                    data = to_candid({
                        user = caller;
                        previousCanisters = Array.subArray<Principal>(Buffer.toArray(ourHalfInstalled.modules), 0, i);
                        packageManager = this;
                    });
                },
            )),
        );

        installedPackages.put(installationId, {
            id = installationId;
            name = ourHalfInstalled.package.base.name;
            version = ourHalfInstalled.package.base.version;
            modules = Buffer.toArray(ourHalfInstalled.modules);
        });
        halfInstalledPackages.delete(installationId);
        // TODO: Modify `installedPackagesByName`.
    };

    system func preupgrade() {
        _ownersSave := Iter.toArray(owners.entries());

        _installedPackagesSave := Iter.toArray(installedPackages.entries());

        _installedPackagesByNameSave := Iter.toArray(installedPackagesByName.entries());

        // TODO:
        // _halfInstalledPackagesSave := Iter.toArray(Iter.map(
        //     halfInstalledPackages,
        //     {
        //         shouldHaveModules: Nat;
        //         name: Common.PackageName;
        //         version: Common.Version;
        //         modules: [Principal];
        //     }
        // ));
    };

    system func postupgrade() {
        owners := HashMap.fromIter(
            _ownersSave.vals(),
            Array.size(_ownersSave),
            Principal.equal,
            Principal.hash,
        );
        _ownersSave := []; // Free memory.

        installedPackages := HashMap.fromIter(
            _installedPackagesSave.vals(),
            Array.size(_installedPackagesSave),
            Nat.equal,
            Int.hash,
        );
        _installedPackagesSave := []; // Free memory.

        installedPackagesByName := HashMap.fromIter(
            _installedPackagesByNameSave.vals(),
            Array.size(_installedPackagesByNameSave),
            Text.equal,
            Text.hash,
        );
        _installedPackagesByNameSave := []; // Free memory.

        // halfInstalledPackages := TODO;
        _halfInstalledPackagesSave := []; // Free memory.
    };

    // Accessor method //

    public query func getInstalledPackage(id: Common.InstallationId): async Common.InstalledPackageInfo {
        let ?result = installedPackages.get(id) else {
            Debug.trap("no such installed package");
        };
        result;
    };

    // Convenience methods //

    public shared({caller}) func addRepository(canister: Principal, name: Text): async () {
        // FIXME: Check caller.
        repositories := Array.append(repositories, [{canister; name}]);
    };

    public query func getRepositories(): async [{canister: Principal; name: Text}] {
        repositories;
    };

    // TODO: More
}