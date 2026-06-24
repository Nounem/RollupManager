public with sharing class AccountHierarchyHelper 
{
    @AuraEnabled(cacheable=true)
    public static Map<String, List<Account>> getAccountHierarchy(Id accountId) {
        Map<String, List<Account>> hierarchy = new Map<String, List<Account>>();
        
        // Récupérer tous les descendants du compte
        List<Account> allDescendants = getAllDescendants(accountId);
        hierarchy.put('Children', allDescendants); 
        
        // Récupérer tous les parents
        List<Account> parents = getAllParentAccounts(accountId);
        hierarchy.put('Parents', parents); 
        
        // Récupérer les frères/sœurs
        List<Account> siblings = getSiblingAccounts(accountId);
        hierarchy.put('Siblings', siblings);
        
        // NOUVEAU: Récupérer les descendants des frères/sœurs
        List<Account> siblingDescendants = new List<Account>();
        for (Account sibling : siblings) {
            siblingDescendants.addAll(getAllDescendants(sibling.Id));
        }
        // Ajouter les descendants des frères/sœurs à la liste des enfants
        allDescendants.addAll(siblingDescendants);
        
        return hierarchy;
    }
    
    /**
     * @description  Récupérer tous les frères/sœurs (comptes avec le même parent)
     * @return List<Account> A list of sibling accounts
     */
    private static List<Account> getSiblingAccounts(Id accountId) {
        List<Account> siblings = new List<Account>();
        Id parentId = null;
        
        // D'abord, récupérer le ParentId du compte actuel
        for (Account acc : [SELECT ParentId FROM Account WHERE Id = :accountId LIMIT 1]) {
            parentId = acc.ParentId;
        }
        
        // Si le compte a un parent, récupérer tous ses enfants (sauf le compte actuel)
        if (parentId != null) {
            siblings = [SELECT Id, Name, ParentId, SIRET__c, NoteCredit__c, BillingCity, TypeCompte__c, 
                        ContactPrincipal__r.Name, Owner.Name, Nb_compteurs__c, 
                        Consommation_Totale_Gaz__c, Consommation_Totale_Elec__c, Parent.Name, Parent.SIRET__c
                      FROM Account 
                      WHERE ParentId = :parentId AND Id != :accountId];
        }
        
        return siblings;
    }

    // Nouvelle méthode pour récupérer TOUS les descendants
    private static List<Account> getAllDescendants(Id rootAccountId) {
        List<Account> allDescendants = new List<Account>();
        
        // Utiliser une structure pour suivre les niveaux de hiérarchie
        Map<Id, List<Account>> childrenByParent = new Map<Id, List<Account>>();
        Set<Id> processedIds = new Set<Id>();
        List<Id> accountIdsToProcess = new List<Id>{rootAccountId};
        
        while (!accountIdsToProcess.isEmpty()) {
            // Récupérer tous les comptes enfants du niveau actuel
            List<Account> children = [SELECT Id, Name, ParentId, SIRET__c, NoteCredit__c, BillingCity, TypeCompte__c, 
                                     ContactPrincipal__r.Name, Owner.Name, Nb_compteurs__c, 
                                     Consommation_Totale_Gaz__c, Consommation_Totale_Elec__c,Parent.Name, Parent.SIRET__c
                                     FROM Account 
                                     WHERE ParentId IN :accountIdsToProcess];
            
            // Ajouter ces enfants à notre liste finale
            allDescendants.addAll(children);
            
            // Préparer le prochain niveau
            List<Id> nextLevelIds = new List<Id>();
            for (Account child : children) {
                if (!processedIds.contains(child.Id)) {
                    nextLevelIds.add(child.Id);
                    processedIds.add(child.Id);
                }
            }
            
            // Passer au niveau suivant
            accountIdsToProcess = nextLevelIds;
        }
        
        return allDescendants;
    }
    
    // Récupérer tous les comptes parents
    private static List<Account> getAllParentAccounts(Id childAccountId) {
        List<Account> parentAccounts = new List<Account>();
        Set<Id> parentIds = new Set<Id>();
        
        // Collecter tous les IDs parents
        Id currentParentId = null;
        
        // Récupérer d'abord le compte initial
        for (Account acc : [SELECT Id, ParentId FROM Account WHERE Id = :childAccountId LIMIT 1]) {
            currentParentId = acc.ParentId;
        }
        
        // Construire la chaîne de parents
        while (currentParentId != null) {
            parentIds.add(currentParentId);
            Id nextParentId = null;
            
            // Récupérer le parent suivant
            for (Account acc : [SELECT Id, ParentId FROM Account WHERE Id = :currentParentId LIMIT 1]) {
                nextParentId = acc.ParentId;
            }
            
            currentParentId = nextParentId;
        }
        
        // Récupérer tous les parents en une seule requête si des parents existent
        if (!parentIds.isEmpty()) {
            parentAccounts = [SELECT Id, Name, ParentId, SIRET__c, NoteCredit__c, BillingCity, TypeCompte__c, 
                             ContactPrincipal__r.Name, Owner.Name, Nb_compteurs__c, 
                             Consommation_Totale_Gaz__c, Consommation_Totale_Elec__c,Parent.Name, Parent.SIRET__c
                             FROM Account WHERE Id IN :parentIds];
        }
        
        return parentAccounts;
    }

      /**
     * Crée des comptes enfants à partir des données CSV importées
     * @param parentId ID du compte parent
     * @param jsonData Données JSON des comptes à créer
     * @return List<Id> Liste des IDs des comptes créés
     */
    @AuraEnabled
    public static List<Id> createChildAccounts(Id parentId, String jsonData) {
        List<Id> createdMeterIds = new List<Id>();
        return createdMeterIds;
    }

    /**
     * Crée des compteurs à partir des données CSV importées
     * @param accountId ID du compte lié
     * @param jsonData Données JSON des compteurs à créer
     * @return List<Id> Liste des IDs des compteurs créés
     */
    @AuraEnabled
    public static List<Id> createMeters(Id accountId, String jsonData) {
        List<Id> createdMeterIds = new List<Id>();

        return createdMeterIds;
    }


}