@isTest
private class AccountHierarchyHelperTest {
    
    @testSetup
    static void setupTestData() {
        // Créer APE NAF pour les comptes
        APE_NAF__c apeNaf = TestDataFactoryApeNaf.createBasic().build();
        insert apeNaf;
        
        // Créer une hiérarchie de comptes en utilisant les factories
        Account grandParent = TestDataFactoryAccount.createClient()
            .setName('Grand Parent Account')
            .setSiret('11111111188155')
            .setApeNaf(apeNaf.Id)
            .build();
        insert grandParent;
        
        Account parent1 = TestDataFactoryAccount.createClient()
            .setName('Parent Account 1')
            .setSiret('22222228822272')
            .setApeNaf(apeNaf.Id)
            .build();
        parent1.ParentId = grandParent.Id;
        parent1.TypeCompte__c = 'Etablissement';
        parent1.NoteCredit__c = '2';
        parent1.BillingCity = 'Lyon';
        insert parent1;
        
        Account account1 = TestDataFactoryAccount.createClient()
            .setName('Test Account 1')
            .setSiret('33336633773333')
            .setApeNaf(apeNaf.Id)
            .build();
        account1.ParentId = parent1.Id;
        account1.BillingCity = 'Marseille';
        account1.Nb_compteurs__c = 5;
        account1.Consommation_Totale_Gaz__c = 1000;
        account1.Consommation_Totale_Elec__c = 2000;
        insert account1;
        
        Account sibling1 = TestDataFactoryAccount.createClient()
            .setName('Sibling Account 1')
            .setSiret('44444447744434')
            .setApeNaf(apeNaf.Id)
            .build();
        sibling1.ParentId = parent1.Id;
        sibling1.BillingCity = 'Toulouse';
        insert sibling1;
        
        // Enfants du compte principal
        List<Account> childAccounts = new List<Account>();
        Account child1 = TestDataFactoryAccount.createClient()
            .setName('Child Account 1')
            .setSiret('55566555554455')
            .setApeNaf(apeNaf.Id)
            .build();
        child1.ParentId = account1.Id;
        child1.TypeCompte__c = 'Etablissement';
        child1.NoteCredit__c = '5';
        child1.BillingCity = 'Nice';
        childAccounts.add(child1);
        
        Account child2 = TestDataFactoryAccount.createClient()
            .setName('Child Account 2')
            .setSiret('66966666966446')
            .setApeNaf(apeNaf.Id)
            .build();
        child2.ParentId = account1.Id;
        child2.BillingCity = 'Bordeaux';
        childAccounts.add(child2);
        insert childAccounts;
        
        // Enfant du frère
        Account siblingChild1 = TestDataFactoryAccount.createClient()
            .setName('Sibling Child 1')
            .setSiret('77977776774777')
            .setApeNaf(apeNaf.Id)
            .build();
        siblingChild1.ParentId = sibling1.Id;
        siblingChild1.BillingCity = 'Lille';
        insert siblingChild1;
        
        // Créer un contact pour tester ContactPrincipal__r
        Contact contact = new Contact(
            FirstName = 'Test',
            LastName = 'Contact',
            AccountId = account1.Id
        );
        insert contact;
        
        // Mettre à jour le compte avec le contact principal
        account1.ContactPrincipal__c = contact.Id;
        update account1;
        
        // Créer des compteurs en utilisant la factory
        Compteur__c compteur1 = TestDataFactoryCompteur.createElecBasseTensionC5()
            .setAccount(account1)
            .setLivraisonDebut(Date.today())
            .setLivraisonFin(Date.today().addYears(1))
            .build();
        compteur1.Name = 'CPT-001';
        compteur1.CodePostal__c = '75001';
        compteur1.CommentaireAdresseInstallation__c = 'Test adresse';
       // compteur1.Code_Acheminement_Optimise__c = 'BLEU-CU4';
        insert compteur1;
    }
    
    @isTest
    static void testGetAccountHierarchy() {
        // Récupérer le compte de test principal
        Account testAccount = [SELECT Id FROM Account WHERE Name = 'Test Account 1' LIMIT 1];
        
        Test.startTest();
        Map<String, List<Account>> hierarchy = AccountHierarchyHelper.getAccountHierarchy(testAccount.Id);
        Test.stopTest();
        
        // Vérifications
        System.assertNotEquals(null, hierarchy, 'La hiérarchie ne doit pas être null');
        System.assertEquals(3, hierarchy.size(), 'La map doit contenir 3 clés');
        System.assert(hierarchy.containsKey('Children'), 'La map doit contenir la clé Children');
        System.assert(hierarchy.containsKey('Parents'), 'La map doit contenir la clé Parents');
        System.assert(hierarchy.containsKey('Siblings'), 'La map doit contenir la clé Siblings');
        
        // Vérifier les enfants (doit inclure les enfants directs + les enfants des frères)
        List<Account> children = hierarchy.get('Children');
        System.assertEquals(3, children.size(), 'Doit avoir 2 enfants directs + 1 enfant du frère');
        
        // Vérifier les parents
        List<Account> parents = hierarchy.get('Parents');
        System.assertEquals(2, parents.size(), 'Doit avoir 2 parents (parent et grand-parent)');
        
        // Vérifier les frères/sœurs
        List<Account> siblings = hierarchy.get('Siblings');
        System.assertEquals(1, siblings.size(), 'Doit avoir 1 frère/sœur');
    }
    
    @isTest
    static void testGetAccountHierarchyNoParent() {
        // Tester avec un compte sans parent en utilisant la factory
        Account orphanAccount = TestDataFactoryAccount.createClient()
            .setName('Orphan Account')
            .setSiret('88888888888888')
            .build();
        insert orphanAccount;
        
        Test.startTest();
        Map<String, List<Account>> hierarchy = AccountHierarchyHelper.getAccountHierarchy(orphanAccount.Id);
        Test.stopTest();
        
        // Vérifications
        System.assertEquals(0, hierarchy.get('Parents').size(), 'Ne doit pas avoir de parents');
        System.assertEquals(0, hierarchy.get('Siblings').size(), 'Ne doit pas avoir de frères/sœurs');
        System.assertEquals(0, hierarchy.get('Children').size(), 'Ne doit pas avoir d\'enfants');
    }
    
    @isTest
    static void testGetAccountHierarchyNoChildren() {
        // Tester avec un compte sans enfants
        Account leafAccount = [SELECT Id FROM Account WHERE Name = 'Child Account 1' LIMIT 1];
        
        Test.startTest();
        Map<String, List<Account>> hierarchy = AccountHierarchyHelper.getAccountHierarchy(leafAccount.Id);
        Test.stopTest();
        
        // Vérifications
        System.assertEquals(0, hierarchy.get('Children').size(), 'Ne doit pas avoir d\'enfants');
        System.assertEquals(3, hierarchy.get('Parents').size(), 'Doit avoir 3 parents');
        System.assertEquals(1, hierarchy.get('Siblings').size(), 'Doit avoir 1 frère/sœur');
    }
    
  
    @isTest
    static void testBulkOperations() {
        // Test des opérations en masse
        List<Account> accounts = [SELECT Id FROM Account WHERE Name LIKE 'Test Account%' OR Name LIKE 'Child Account%' LIMIT 5];
        
        Test.startTest();
        for (Account acc : accounts) {
            Map<String, List<Account>> hierarchy = AccountHierarchyHelper.getAccountHierarchy(acc.Id);
            System.assertNotEquals(null, hierarchy, 'La hiérarchie ne doit pas être null pour ' + acc.Id);
        }
        Test.stopTest();
    }
}