@isTest
private class RollupHelperTest {

    static {
        RollupTriggerControl.disabled = true;
    }

    // ─── Données partagées entre tous les tests ────────────────────────────────

    @TestSetup
    static void setup() {
        insert new List<Account>{
            new Account(Name = 'Compte A'),
            new Account(Name = 'Compte B')
        };
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    static RollupHelper.RollupConfig buildConfig() {
        RollupHelper.RollupConfig c = new RollupHelper.RollupConfig();
        c.childObject       = 'Opportunity';
        c.relationshipField = 'AccountId';
        c.fieldToAggregate  = 'Amount';
        c.aggregateFunction = 'SUM';
        c.parentObject      = 'Account';
        c.targetField       = 'Total_CA__c';
        c.filterCriteria    = null;
        c.alwaysRecalculate = false;
        return c;
    }

    static Account getAccount(String name) {
        return [SELECT Id, Total_CA__c FROM Account WHERE Name = :name LIMIT 1];
    }

    static Opportunity buildOpp(Id accId, Decimal amount, String stage) {
        return new Opportunity(
            AccountId = accId,
            Name      = 'Opp ' + amount,
            Amount    = amount,
            StageName = stage,
            CloseDate = Date.today().addDays(30)
        );
    }

    // ─── Cas 1 : INSERT — le total parent augmente ────────────────────────────

    @isTest
    static void testInsert() {
        Account acc = getAccount('Compte A');
        List<Opportunity> opps = new List<Opportunity>{
            buildOpp(acc.Id, 100, 'Prospecting'),
            buildOpp(acc.Id, 200, 'Prospecting')
        };
        insert opps;

        Test.startTest();
        RollupHelper.calculate(buildConfig(), opps, null, true, false, false, false);
        Test.stopTest();

        System.assertEquals(300, getAccount('Compte A').Total_CA__c, 'SUM après INSERT doit être 300');
    }

    // ─── Cas 2 : UPDATE du champ agrégé ───────────────────────────────────────

    @isTest
    static void testUpdateAggregatedField() {
        Account acc = getAccount('Compte A');
        Opportunity opp = buildOpp(acc.Id, 500, 'Prospecting');
        insert opp;
        RollupHelper.calculate(buildConfig(), new List<SObject>{ opp }, null, true, false, false, false);

        // Capturer l'état avant modification (Trigger.old)
        List<Opportunity> oldList = [SELECT Id, AccountId, Amount FROM Opportunity WHERE Id = :opp.Id];
        opp.Amount = 800;
        update opp;
        List<Opportunity> newList = [SELECT Id, AccountId, Amount FROM Opportunity WHERE Id = :opp.Id];

        Test.startTest();
        RollupHelper.calculate(buildConfig(), newList, oldList, false, true, false, false);
        Test.stopTest();

        System.assertEquals(800, getAccount('Compte A').Total_CA__c, 'Total doit refléter le nouveau montant');
    }

    // ─── Cas 3 : UPDATE sans changement pertinent — aucun recalcul ────────────
    // Vérifie l'optimisation : si ni fieldToAggregate ni relationshipField ne changent,
    // RollupHelper retourne immédiatement sans toucher au parent.

    @isTest
    static void testUpdateNoRelevantChange() {
        Account acc = getAccount('Compte A');
        Opportunity opp = buildOpp(acc.Id, 700, 'Prospecting');
        insert opp;
        RollupHelper.calculate(buildConfig(), new List<SObject>{ opp }, null, true, false, false, false);

        // Forcer le champ cible à null pour détecter si le moteur le remet à jour
        update new Account(Id = acc.Id, Total_CA__c = null);

        // Modifier uniquement Description (hors config) — Amount et AccountId restent identiques
        List<Opportunity> before = [SELECT Id, AccountId, Amount FROM Opportunity WHERE Id = :opp.Id];
        opp.Description = 'Changement sans impact sur le rollup';
        update opp;
        List<Opportunity> after = [SELECT Id, AccountId, Amount FROM Opportunity WHERE Id = :opp.Id];

        Test.startTest();
        RollupHelper.calculate(buildConfig(), after, before, false, true, false, false);
        Test.stopTest();

        // Le moteur n'a rien fait : Total_CA__c reste null
        System.assertEquals(null, getAccount('Compte A').Total_CA__c,
            'Aucun recalcul si le champ agrégé et la relation sont inchangés');
    }

    // ─── Cas 4 : UPDATE reparentage — deux parents recalculés ─────────────────

    @isTest
    static void testReparenting() {
        Account accA = getAccount('Compte A');
        Account accB = getAccount('Compte B');
        Opportunity opp = buildOpp(accA.Id, 1000, 'Prospecting');
        insert opp;
        RollupHelper.calculate(buildConfig(), new List<SObject>{ opp }, null, true, false, false, false);
        System.assertEquals(1000, getAccount('Compte A').Total_CA__c, 'Pré-condition : A = 1000');

        List<Opportunity> oldList = [SELECT Id, AccountId, Amount FROM Opportunity WHERE Id = :opp.Id];
        opp.AccountId = accB.Id;
        update opp;
        List<Opportunity> newList = [SELECT Id, AccountId, Amount FROM Opportunity WHERE Id = :opp.Id];

        Test.startTest();
        RollupHelper.calculate(buildConfig(), newList, oldList, false, true, false, false);
        Test.stopTest();

        System.assertEquals(0,    getAccount('Compte A').Total_CA__c, 'Compte A doit être remis à 0');
        System.assertEquals(1000, getAccount('Compte B').Total_CA__c, 'Compte B doit recevoir 1000');
    }

    // ─── Cas 5 : DELETE — le total diminue ────────────────────────────────────

    @isTest
    static void testDelete() {
        Account acc = getAccount('Compte A');
        Opportunity opp = buildOpp(acc.Id, 400, 'Prospecting');
        insert opp;
        RollupHelper.calculate(buildConfig(), new List<SObject>{ opp }, null, true, false, false, false);
        System.assertEquals(400, getAccount('Compte A').Total_CA__c, 'Pré-condition : A = 400');

        List<Opportunity> deleted = [SELECT Id, AccountId, Amount FROM Opportunity WHERE Id = :opp.Id];
        delete opp;

        Test.startTest();
        RollupHelper.calculate(buildConfig(), null, deleted, false, false, true, false);
        Test.stopTest();

        System.assertEquals(0, getAccount('Compte A').Total_CA__c, 'Total après DELETE doit être 0');
    }

    // ─── Cas 6 : UNDELETE — le total est restauré ─────────────────────────────

    @isTest
    static void testUndelete() {
        Account acc = getAccount('Compte A');
        Opportunity opp = buildOpp(acc.Id, 600, 'Prospecting');
        insert opp;
        delete opp;

        undelete opp;
        List<Opportunity> restored = [SELECT Id, AccountId, Amount FROM Opportunity WHERE Id = :opp.Id];

        Test.startTest();
        RollupHelper.calculate(buildConfig(), restored, null, false, false, false, true);
        Test.stopTest();

        System.assertEquals(600, getAccount('Compte A').Total_CA__c, 'Total après UNDELETE doit être 600');
    }

    // ─── Cas 7 : BULK 200 enregistrements — governor limits ───────────────────

    @isTest
    static void testBulk() {
        Account acc = getAccount('Compte A');
        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < 200; i++) {
            opps.add(buildOpp(acc.Id, 10, 'Prospecting'));
        }
        insert opps;

        Test.startTest();
        RollupHelper.calculate(buildConfig(), opps, null, true, false, false, false);
        Test.stopTest();

        System.assertEquals(2000, getAccount('Compte A').Total_CA__c, '200 × 10 = 2000');
    }

    // ─── Cas 8 : filtre actif — seuls les enregistrements filtrés comptent ─────

    @isTest
    static void testFilterCriteria() {
        Account acc = getAccount('Compte A');
        List<Opportunity> opps = new List<Opportunity>{
            buildOpp(acc.Id, 500, 'Closed Won'),   // doit être compté
            buildOpp(acc.Id, 300, 'Prospecting')   // exclu par le filtre
        };
        insert opps;

        RollupHelper.RollupConfig config = buildConfig();
        config.filterCriteria   = 'StageName = \'Closed Won\'';
        config.alwaysRecalculate = true; // StageName n'est pas fieldToAggregate

        Test.startTest();
        RollupHelper.calculate(config, opps, null, true, false, false, false);
        Test.stopTest();

        System.assertEquals(500, getAccount('Compte A').Total_CA__c,
            'Seul le Closed Won (500) doit être compté');
    }

    // ─── Cas 9 : COUNT ────────────────────────────────────────────────────────

    @isTest
    static void testCount() {
        Account acc = getAccount('Compte A');
        List<Opportunity> opps = new List<Opportunity>{
            buildOpp(acc.Id, 100, 'Prospecting'),
            buildOpp(acc.Id, 200, 'Prospecting'),
            buildOpp(acc.Id, 300, 'Prospecting')
        };
        insert opps;

        RollupHelper.RollupConfig config = buildConfig();
        config.aggregateFunction = 'COUNT';
        config.fieldToAggregate  = null;

        Test.startTest();
        RollupHelper.calculate(config, opps, null, true, false, false, false);
        Test.stopTest();

        System.assertEquals(3, getAccount('Compte A').Total_CA__c, 'COUNT doit retourner 3');
    }

    // ─── Cas 10 : relation nulle — aucune exception ───────────────────────────

    @isTest
    static void testNullRelationship() {
        Opportunity opp = buildOpp(null, 100, 'Prospecting'); // pas d'Account
        insert opp;

        Test.startTest();
        RollupHelper.calculate(buildConfig(), new List<SObject>{ opp }, null, true, false, false, false);
        Test.stopTest();

        System.assert(true, 'Aucune exception pour un enregistrement sans parent');
    }

    // ─── Cas 11 : garde anti-récursion ────────────────────────────────────────
    // Vérifie que si calculate() est appelé alors qu'il tourne déjà pour la même
    // clé (ChildObject:TargetField), le second appel sort immédiatement sans DML.

    @isTest
    static void testRecursionGuard() {
        Account acc = getAccount('Compte A');
        Opportunity opp = buildOpp(acc.Id, 100, 'Prospecting');
        insert opp;

        // Simuler une exécution en cours pour cette clé
        RollupHelper.RUNNING.add('Opportunity:Total_CA__c');

        Test.startTest();
        RollupHelper.calculate(buildConfig(), new List<SObject>{ opp }, null, true, false, false, false);
        Test.stopTest();

        // Le moteur a retourné immédiatement → Total_CA__c reste null
        System.assertEquals(null, getAccount('Compte A').Total_CA__c,
            'La récursion doit être bloquée par le guard');

        // Nettoyage explicite pour ne pas affecter d'autres tests
        RollupHelper.RUNNING.clear();
    }

    // ─── Cas 12 : validation de configuration ─────────────────────────────────

    @isTest
    static void testConfigValidation() {
        // Config null
        try {
            RollupHelper.calculate(null, new List<SObject>(), null, true, false, false, false);
            System.assert(false, 'RollupException attendue pour config null');
        } catch (RollupHelper.RollupException e) {
            System.assert(e.getMessage().contains('null'), e.getMessage());
        }

        // childObject vide
        RollupHelper.RollupConfig c = buildConfig();
        c.childObject = '';
        try {
            RollupHelper.calculate(c, new List<SObject>(), null, true, false, false, false);
            System.assert(false, 'RollupException attendue pour childObject vide');
        } catch (RollupHelper.RollupException e) {
            System.assert(e.getMessage().contains('childObject'), e.getMessage());
        }

        // aggregateFunction invalide
        c = buildConfig();
        c.aggregateFunction = 'INVALID';
        try {
            RollupHelper.calculate(c, new List<SObject>(), null, true, false, false, false);
            System.assert(false, 'RollupException attendue pour fonction invalide');
        } catch (RollupHelper.RollupException e) {
            System.assert(e.getMessage().contains('invalide'), e.getMessage());
        }

        // fieldToAggregate manquant pour SUM
        c = buildConfig();
        c.fieldToAggregate = null;
        try {
            RollupHelper.calculate(c, new List<SObject>(), null, true, false, false, false);
            System.assert(false, 'RollupException attendue pour fieldToAggregate manquant');
        } catch (RollupHelper.RollupException e) {
            System.assert(e.getMessage().contains('fieldToAggregate'), e.getMessage());
        }
    }

    // ─── Cas 13 : calculateAll — deux rollups sur le même objet ───────────────

    @isTest
    static void testCalculateAll() {
        Account acc = getAccount('Compte A');
        List<Opportunity> opps = new List<Opportunity>{
            buildOpp(acc.Id, 100, 'Prospecting'),
            buildOpp(acc.Id, 200, 'Prospecting')
        };
        insert opps;

        RollupHelper.RollupConfig configSum = buildConfig();

        RollupHelper.RollupConfig configCount = buildConfig();
        configCount.aggregateFunction = 'COUNT';
        configCount.fieldToAggregate  = null;
        configCount.targetField       = 'Total_CA__c'; // réutilise le même champ pour le test

        List<RollupHelper.RollupConfig> configs = new List<RollupHelper.RollupConfig>{
            configSum, configCount
        };

        Test.startTest();
        RollupHelper.calculateAll(configs, opps, null, true, false, false, false);
        Test.stopTest();

        // Le dernier rollup (COUNT = 2) écrase le premier (SUM = 300) — comportement attendu
        System.assertEquals(2, getAccount('Compte A').Total_CA__c,
            'calculateAll exécute les configs dans l\'ordre, le COUNT écrase le SUM');
    }

    // ─── Cas 14 : parentFilter — seuls les parents éligibles reçoivent la MAJ ─
    // Simule : "ne calculer que pour les Accounts dont BillingCity = 'Paris'"

    @isTest
    static void testParentFilter() {
        Account paris = new Account(Name = 'Paris', BillingCity = 'Paris');
        Account lyon  = new Account(Name = 'Lyon',  BillingCity = 'Lyon');
        insert new List<Account>{ paris, lyon };

        List<Opportunity> opps = new List<Opportunity>{
            buildOpp(paris.Id, 500, 'Prospecting'),
            buildOpp(lyon.Id,  300, 'Prospecting')
        };
        insert opps;

        RollupHelper.RollupConfig config = buildConfig();
        config.parentFilter = 'BillingCity = \'Paris\'';

        Test.startTest();
        RollupHelper.calculate(config, opps, null, true, false, false, false);
        Test.stopTest();

        Account resParis = [SELECT Total_CA__c FROM Account WHERE Id = :paris.Id];
        Account resLyon  = [SELECT Total_CA__c FROM Account WHERE Id = :lyon.Id];

        System.assertEquals(500,  resParis.Total_CA__c, 'Paris (éligible) doit avoir 500');
        System.assertEquals(null, resLyon.Total_CA__c,  'Lyon (exclu par parentFilter) ne doit pas être touché');
    }

    // ─── Cas 15 : parentFilter — aucun parent éligible, aucun DML ─────────────

    @isTest
    static void testParentFilterNoMatch() {
        Account acc = getAccount('Compte A');
        List<Opportunity> opps = new List<Opportunity>{ buildOpp(acc.Id, 100, 'Prospecting') };
        insert opps;

        RollupHelper.RollupConfig config = buildConfig();
        config.parentFilter = 'BillingCity = \'Paris\''; // Compte A n'a pas de BillingCity

        Test.startTest();
        RollupHelper.calculate(config, opps, null, true, false, false, false);
        Test.stopTest();

        System.assertEquals(null, getAccount('Compte A').Total_CA__c,
            'Aucun DML si aucun parent ne passe le parentFilter');
    }

    // ─── Cas 16 : plusieurs enfants différents → même parent ──────────────────
    // Simule deux triggers indépendants (Opportunity + Case) qui mettent à jour
    // des champs différents sur Account. Les calculs sont indépendants.

    @isTest
    static void testMultipleChildObjects() {
        Account acc = getAccount('Compte A');

        // Rollup 1 : SUM Amount des Opportunités → Total_CA__c
        List<Opportunity> opps = new List<Opportunity>{
            buildOpp(acc.Id, 400, 'Prospecting'),
            buildOpp(acc.Id, 600, 'Prospecting')
        };
        insert opps;

        // Rollup 2 : COUNT Cases → simulé via un second appel avec une config COUNT
        // (en prod ce serait un second trigger CaseRollupTrigger)
        List<Case> cases = new List<Case>{
            new Case(AccountId = acc.Id, Subject = 'Case 1', Status = 'New', Origin = 'Email'),
            new Case(AccountId = acc.Id, Subject = 'Case 2', Status = 'New', Origin = 'Email')
        };
        insert cases;

        RollupHelper.RollupConfig configOpp = buildConfig();

        RollupHelper.RollupConfig configCase = new RollupHelper.RollupConfig();
        configCase.childObject       = 'Case';
        configCase.relationshipField = 'AccountId';
        configCase.fieldToAggregate  = null;
        configCase.aggregateFunction = 'COUNT';
        configCase.parentObject      = 'Account';
        configCase.targetField       = 'Total_CA__c'; // réutilise Total_CA__c pour éviter un second champ custom dans le test
        configCase.filterCriteria    = null;
        configCase.alwaysRecalculate = false;

        Test.startTest();
        // Simule le trigger Opportunity
        RollupHelper.calculate(configOpp, opps, null, true, false, false, false);
        // Simule le trigger Case — clé différente, pas de conflit de récursion
        RollupHelper.calculate(configCase, cases, null, true, false, false, false);
        Test.stopTest();

        // Le COUNT(Case) = 2 a écrasé le SUM(Amount) = 1000
        // En prod les deux configs ciblent des champs différents — pas d'écrasement
        System.assertEquals(2, getAccount('Compte A').Total_CA__c,
            'Le second rollup (COUNT Case) écrase le premier car ils ciblent le même champ dans ce test');
    }

    @isTest
    static void testAggregateFunctionIsNormalized() {
        Account acc = getAccount('Compte A');
        List<Opportunity> opps = new List<Opportunity>{
            buildOpp(acc.Id, 100, 'Prospecting'),
            buildOpp(acc.Id, 200, 'Prospecting')
        };
        insert opps;

        RollupHelper.RollupConfig config = buildConfig();
        config.aggregateFunction = 'sum';

        Test.startTest();
        RollupHelper.calculate(config, opps, null, true, false, false, false);
        Test.stopTest();

        System.assertEquals(300, getAccount('Compte A').Total_CA__c,
            'La fonction en minuscule doit etre normalisee');
    }

    @isTest
    static void testWatchedFieldsLimitUpdateRecalculation() {
        Account acc = getAccount('Compte A');
        Opportunity opp = buildOpp(acc.Id, 100, 'Prospecting');
        insert opp;

        RollupHelper.RollupConfig config = buildConfig();
        config.filterCriteria = 'StageName = \'Closed Won\'';
        config.alwaysRecalculate = false;
        config.watchedFields = new Set<String>{ 'StageName' };

        RollupHelper.calculate(config, new List<SObject>{ opp }, null, true, false, false, false);
        System.assertEquals(0, getAccount('Compte A').Total_CA__c,
            'Prospecting ne doit pas passer le filtre Closed Won');

        update new Account(Id = acc.Id, Total_CA__c = null);

        List<Opportunity> beforeDescription = [
            SELECT Id, AccountId, Amount, StageName FROM Opportunity WHERE Id = :opp.Id
        ];
        opp.Description = 'Description only';
        update opp;
        List<Opportunity> afterDescription = [
            SELECT Id, AccountId, Amount, StageName FROM Opportunity WHERE Id = :opp.Id
        ];

        RollupHelper.calculate(config, afterDescription, beforeDescription, false, true, false, false);
        System.assertEquals(null, getAccount('Compte A').Total_CA__c,
            'Un champ non surveille ne doit pas declencher le recalcul');

        List<Opportunity> beforeStage = [
            SELECT Id, AccountId, Amount, StageName FROM Opportunity WHERE Id = :opp.Id
        ];
        opp.StageName = 'Closed Won';
        update opp;
        List<Opportunity> afterStage = [
            SELECT Id, AccountId, Amount, StageName FROM Opportunity WHERE Id = :opp.Id
        ];

        RollupHelper.calculate(config, afterStage, beforeStage, false, true, false, false);
        System.assertEquals(100, getAccount('Compte A').Total_CA__c,
            'Le changement de StageName doit declencher le recalcul');
    }

    @isTest
    static void testAverageReturnsNullWithoutMatchingChildren() {
        Account acc = getAccount('Compte A');
        Opportunity opp = buildOpp(acc.Id, 100, 'Prospecting');
        insert opp;

        RollupHelper.RollupConfig config = buildConfig();
        config.aggregateFunction = 'AVG';

        RollupHelper.calculate(config, new List<SObject>{ opp }, null, true, false, false, false);
        System.assertEquals(100, getAccount('Compte A').Total_CA__c,
            'Pre-condition : AVG doit valoir 100');

        List<Opportunity> deleted = [SELECT Id, AccountId, Amount FROM Opportunity WHERE Id = :opp.Id];
        delete opp;

        RollupHelper.calculate(config, null, deleted, false, false, true, false);
        System.assertEquals(null, getAccount('Compte A').Total_CA__c,
            'AVG sans enfant correspondant doit remettre le champ a null');
    }

    @isTest
    static void testSchemaValidationForUnknownField() {
        RollupHelper.RollupConfig config = buildConfig();
        config.fieldToAggregate = 'Champ_Inexistant__c';

        try {
            RollupHelper.calculate(config, new List<SObject>(), null, true, false, false, false);
            System.assert(false, 'RollupException attendue pour champ inexistant');
        } catch (RollupHelper.RollupException e) {
            System.assert(e.getMessage().contains('champ introuvable'), e.getMessage());
        }
    }

    @isTest
    static void testCalculateAllIgnoresInvalidConfigAndContinues() {
        Account acc = getAccount('Compte A');
        List<Opportunity> opps = new List<Opportunity>{
            buildOpp(acc.Id, 100, 'Prospecting'),
            buildOpp(acc.Id, 200, 'Prospecting')
        };
        insert opps;

        RollupHelper.RollupConfig invalidConfig = buildConfig();
        invalidConfig.childObject = 'Objet_Inexistant__c';

        List<RollupHelper.RollupConfig> configs = new List<RollupHelper.RollupConfig>{
            invalidConfig,
            buildConfig()
        };

        Test.startTest();
        RollupHelper.calculateAll(configs, opps, null, true, false, false, false);
        Test.stopTest();

        System.assertEquals(300, getAccount('Compte A').Total_CA__c,
            'La config valide doit s executer meme si une autre config est invalide');
        System.assertEquals(1, RollupHelper.LAST_ERRORS.size(),
            'La config invalide doit etre loggee sans bloquer les suivantes');
    }
}
