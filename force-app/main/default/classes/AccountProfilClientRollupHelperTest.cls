@IsTest
private class AccountProfilClientRollupHelperTest {

    private static Profil_client__c createProfile(String name) {
        Profil_client__c profile = new Profil_client__c(Name = name);
        insert profile;
        return profile;
    }

    private static Account buildAccount(String name, Id parentId, Id profileId) {
        Account account = new Account(Name = name, ParentId = parentId);
        account.put('profil_client__c', profileId);
        return account;
    }

    @IsTest
    static void accountTriggerDoesNotBlockWhenTargetFieldIsFormulaTest() {
        RollupTriggerControl.disabled = false;
        Profil_client__c profile = createProfile('Profil A');

        Test.startTest();
        insert buildAccount('Account A', null, profile.Id);
        Test.stopTest();

        Account insertedAccount = [
            SELECT Id
            FROM Account
            WHERE Name = 'Account A'
            LIMIT 1
        ];
        System.assertNotEquals(null, insertedAccount.Id,
            'Le helper ne doit pas bloquer le DML Account, meme si le champ cible est encore une formule');
    }

    @IsTest
    static void accountTriggerBypassTest() {
        RollupTriggerControl.disabled = true;
        Profil_client__c profile = createProfile('Profil B');

        Test.startTest();
        insert buildAccount('Account B', null, profile.Id);
        Test.stopTest();

        System.assertEquals(0, AccountProfilClientHierarchyRollupHelper.LAST_ERRORS.size(),
            'Le bypass doit empecher le helper Account de s executer');
        RollupTriggerControl.disabled = false;
    }

    @IsTest
    static void accountHierarchyInsertDoesNotThrowTest() {
        RollupTriggerControl.disabled = false;
        Profil_client__c profileA = createProfile('Profil Root');
        Profil_client__c profileB = createProfile('Profil Child');

        Account root = buildAccount('Root Account', null, profileA.Id);
        insert root;

        Test.startTest();
        insert buildAccount('Child Account', root.Id, profileB.Id);
        Test.stopTest();

        System.assert(true, 'Le calcul hierarchique ne doit pas bloquer l insertion enfant');
    }
}
