/**
 * Provisions the integration principal described in the solution design: an API-only user on a
 * Salesforce Integration license, holding CPQ_Integration_User and nothing else.
 *
 *   sf apex run --file scripts/apex/create-integration-user.apex -o <alias>
 *
 * Re-runnable. If the user already exists it is left alone and only the permission set assignment
 * is reconciled, so this can be used to repair an org as well as to build one.
 *
 * This user is the "Run As" principal for the Connected App's client credentials flow. It has no
 * password and never logs into the UI.
 *
 * On the licence, because it is not what the design first assumed. A Salesforce Integration licence
 * is the obvious choice and it cannot work: it refuses Read on Account, Opportunity and Product2,
 * and Pricebook2 depends on Product2. Since an OpportunityLineItem cannot be inserted without a
 * PricebookEntryId, this API cannot run on that licence at all. So it takes a full Salesforce seat
 * on the most restrictive profile available, and every privilege it has comes from the permission
 * set rather than the profile.
 */
final String USERNAME = 'svc.revtech.cpq@revtech.luxury.demo';
final String PERMSET = 'CPQ_Integration_User';
final String PROFILE = 'Minimum Access - Salesforce';

Profile p = [SELECT Id, Name FROM Profile WHERE Name = :PROFILE LIMIT 1];
List<User> existing = [SELECT Id, Username, IsActive, ProfileId FROM User WHERE Username = :USERNAME LIMIT 1];
User svc;

if (existing.isEmpty()) {
    svc = new User(
        Username = USERNAME,
        LastName = 'CPQ Integration',
        Email = 'bruno.romano182@gmail.com',
        Alias = 'svccpq',
        ProfileId = p.Id,
        TimeZoneSidKey = 'America/Los_Angeles',
        LocaleSidKey = 'en_US',
        EmailEncodingKey = 'UTF-8',
        LanguageLocaleKey = 'en_US'
    );
    insert svc;
    System.debug('created integration user ' + svc.Id);
} else {
    svc = existing[0];
    System.debug('integration user already exists ' + svc.Id);

    // Reconcile rather than assume. A profile changed by hand in Setup is the single easiest way
    // to silently void the least-privilege posture, and re-running this should repair it.
    if (svc.ProfileId != p.Id) {
        svc.ProfileId = p.Id;
        update svc;
        System.debug('profile corrected back to ' + PROFILE);
    }
}

// LoggerLogCreator is Nebula's: without it the principal cannot publish a LogEntryEvent__e, and
// the failures most worth seeing are silently dropped. Successes still return 200, so the gap is
// invisible until someone goes looking for a log that was never written.
Set<String> required = new Set<String>{ PERMSET, 'LoggerLogCreator' };

Map<String, Id> byName = new Map<String, Id>();
for (PermissionSet ps : [SELECT Id, Name FROM PermissionSet WHERE Name IN :required]) {
    byName.put(ps.Name, ps.Id);
}

Set<Id> held = new Set<Id>();
for (PermissionSetAssignment a : [
    SELECT PermissionSetId
    FROM PermissionSetAssignment
    WHERE AssigneeId = :svc.Id AND PermissionSetId IN :byName.values()
]) {
    held.add(a.PermissionSetId);
}

List<PermissionSetAssignment> toAssign = new List<PermissionSetAssignment>();
for (String name : required) {
    Id psId = byName.get(name);
    if (psId == null) {
        System.debug('WARNING: permission set not found, is Nebula Logger installed? ' + name);
    } else if (!held.contains(psId)) {
        toAssign.add(new PermissionSetAssignment(AssigneeId = svc.Id, PermissionSetId = psId));
        System.debug('assigning ' + name);
    } else {
        System.debug(name + ' already assigned');
    }
}
if (!toAssign.isEmpty()) {
    insert toAssign;
}

System.debug('--- integration principal ready ---');
System.debug('username: ' + USERNAME);
System.debug('user id:  ' + svc.Id);
System.debug('Set this user as the Client Credentials "Run As" user on the Connected App.');
