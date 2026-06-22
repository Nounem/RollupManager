/**
 * Moteur générique de calcul rollup entre deux objets Salesforce.
 *
 * without sharing : le calcul agrège TOUS les enregistrements enfants indépendamment
 * des droits du contexte d'exécution, identique au comportement natif des RUSF.
 * Si la restriction par profil est voulue, passer à "with sharing".
 */
public without sharing class RollupHelper {

    // Évite d'appeler getGlobalDescribe() plusieurs fois dans la même transaction
    private static final Map<String, Schema.SObjectType> SOBJECT_CACHE =
        new Map<String, Schema.SObjectType>();

    // Clé : 'ChildObject:TargetField'
    // Permet à plusieurs rollups sur le même objet de coexister sans bloquer mutuellement
    @TestVisible
    private static final Set<String> RUNNING = new Set<String>();

    // ─── Modèle de configuration ──────────────────────────────────────────────

    public class RollupConfig {
        public String  childObject;         // API name objet enfant     ex : 'Opportunity'
        public String  relationshipField;   // Champ relation sur enfant  ex : 'AccountId'
        public String  fieldToAggregate;    // Champ à agréger            ex : 'Amount' (null si COUNT)
        public String  aggregateFunction;   // SUM | COUNT | MIN | MAX | AVG
        public String  parentObject;        // API name objet parent      ex : 'Account'
        public String  targetField;         // Champ cible sur parent     ex : 'Total_CA__c'
        public String  filterCriteria;      // Clause WHERE sur les enfants — null = aucun filtre
        public String  parentFilter;        // Clause WHERE sur les parents — null = tous les parents
                                            // ex : 'RecordType.DeveloperName = \'Client\''
                                            // Seuls les parents qui matchent reçoivent la mise à jour
        // Mettre true si filterCriteria porte sur un champ autre que fieldToAggregate
        // (ex : filtre sur StageName mais on agrège Amount).
        // Par défaut false : recalcul uniquement si fieldToAggregate ou relationshipField change.
        public Boolean alwaysRecalculate = false;
    }

    public class RollupException extends Exception {}

    // ─── Point d'entrée : un seul rollup ─────────────────────────────────────

    public static void calculate(
        RollupConfig  config,
        List<SObject> newList,
        List<SObject> oldList,
        Boolean       isInsert,
        Boolean       isUpdate,
        Boolean       isDelete,
        Boolean       isUndelete
    ) {
        assertConfig(config);

        String key = config.childObject + ':' + config.targetField;
        if (RUNNING.contains(key)) return;

        Set<Id> parentIds = collectParentIds(
            config, newList, oldList, isInsert, isUpdate, isDelete, isUndelete
        );
        if (parentIds.isEmpty()) return;

        // Filtre sur le parent : exclure les parents qui ne matchent pas parentFilter
        if (String.isNotBlank(config.parentFilter)) {
            parentIds = filterParentIds(config, parentIds);
            if (parentIds.isEmpty()) return;
        }

        RUNNING.add(key);
        try {
            persist(config, parentIds, aggregate(config, parentIds));
        } finally {
            RUNNING.remove(key);
        }
    }

    // ─── Point d'entrée : plusieurs rollups sur le même objet enfant ──────────

    public static void calculateAll(
        List<RollupConfig> configs,
        List<SObject>      newList,
        List<SObject>      oldList,
        Boolean            isInsert,
        Boolean            isUpdate,
        Boolean            isDelete,
        Boolean            isUndelete
    ) {
        for (RollupConfig config : configs) {
            calculate(config, newList, oldList, isInsert, isUpdate, isDelete, isUndelete);
        }
    }

    // ─── Étape 1 : identifier les IDs parent impactés ─────────────────────────

    private static Set<Id> collectParentIds(
        RollupConfig  config,
        List<SObject> newList,
        List<SObject> oldList,
        Boolean       isInsert,
        Boolean       isUpdate,
        Boolean       isDelete,
        Boolean       isUndelete
    ) {
        Set<Id> ids = new Set<Id>();

        if (isDelete) {
            for (SObject rec : oldList) {
                Id pid = (Id) rec.get(config.relationshipField);
                if (pid != null) ids.add(pid);
            }

        } else if (isInsert || isUndelete) {
            for (SObject rec : newList) {
                Id pid = (Id) rec.get(config.relationshipField);
                if (pid != null) ids.add(pid);
            }

        } else if (isUpdate) {
            for (Integer i = 0; i < newList.size(); i++) {
                Id newPid = (Id) newList[i].get(config.relationshipField);
                Id oldPid = (Id) oldList[i].get(config.relationshipField);

                Boolean relationChanged = newPid != oldPid;

                // COUNT ne dépend d'aucun champ agrégé : seule la relation compte
                Boolean valueChanged = !config.alwaysRecalculate
                    && config.aggregateFunction != 'COUNT'
                    && newList[i].get(config.fieldToAggregate) != oldList[i].get(config.fieldToAggregate);

                // alwaysRecalculate : recalcul systématique si le filterCriteria
                // porte sur un champ autre que fieldToAggregate
                Boolean forceRecalc = config.alwaysRecalculate == true && (newPid != null || oldPid != null);

                if (forceRecalc || relationChanged || valueChanged) {
                    if (newPid != null) ids.add(newPid);
                    if (oldPid != null) ids.add(oldPid); // reparentage : les deux parents sont recalculés
                }
            }
        }

        return ids;
    }

    // ─── Étape 2 : requête d'agrégation SOQL dynamique ───────────────────────

    private static Map<Id, Decimal> aggregate(RollupConfig config, Set<Id> parentIds) {
        Map<Id, Decimal> valueMap = new Map<Id, Decimal>();
        for (Id pid : parentIds) valueMap.put(pid, 0); // parents sans enfants correspondants → 0

        String aggExpr = config.aggregateFunction == 'COUNT'
            ? 'COUNT(Id)'
            : config.aggregateFunction + '(' + config.fieldToAggregate + ')';

        String soql = 'SELECT '  + config.relationshipField + ' parentId, '
                    +              aggExpr                   + ' rollupValue '
                    + 'FROM '    + config.childObject
                    + ' WHERE '  + config.relationshipField  + ' IN :parentIds';

        if (String.isNotBlank(config.filterCriteria)) {
            soql += ' AND (' + config.filterCriteria + ')';
        }

        soql += ' GROUP BY ' + config.relationshipField;

        for (AggregateResult ar : Database.query(soql)) {
            Id     pid    = (Id) ar.get('parentId');
            Object rawVal = ar.get('rollupValue');

            if (pid == null || rawVal == null) continue;

            // COUNT retourne Integer, SUM / MIN / MAX / AVG retournent Decimal
            valueMap.put(pid, rawVal instanceof Integer
                ? Decimal.valueOf((Integer) rawVal)
                : (Decimal) rawVal);
        }

        return valueMap;
    }

    // ─── Étape 3 : écriture sur les parents ───────────────────────────────────

    private static void persist(
        RollupConfig     config,
        Set<Id>          parentIds,
        Map<Id, Decimal> valueMap
    ) {
        Schema.SObjectType parentType = getSObjectType(config.parentObject);
        List<SObject> toUpdate = new List<SObject>();

        for (Id pid : parentIds) {
            SObject parent = parentType.newSObject(pid);
            parent.put(config.targetField, valueMap.containsKey(pid) ? valueMap.get(pid) : 0);
            toUpdate.add(parent);
        }

        if (toUpdate.isEmpty()) return;

        // allOrNone = false : un parent en erreur ne bloque pas les autres
        List<Database.SaveResult> results = Database.update(toUpdate, false);
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                System.debug(
                    LoggingLevel.ERROR,
                    'RollupHelper — échec parent ' + toUpdate[i].Id
                    + ' [' + config.parentObject + '.' + config.targetField + '] : '
                    + results[i].getErrors()[0].getMessage()
                );
            }
        }
    }

    // ─── Filtre sur le parent ─────────────────────────────────────────────────
    // Retourne uniquement les IDs dont le parent vérifie parentFilter.
    // Les parents exclus ne reçoivent ni mise à jour ni remise à zéro.

    private static Set<Id> filterParentIds(RollupConfig config, Set<Id> parentIds) {
        String soql = 'SELECT Id FROM ' + config.parentObject
                    + ' WHERE Id IN :parentIds AND (' + config.parentFilter + ')';
        Set<Id> allowed = new Set<Id>();
        for (SObject rec : Database.query(soql)) {
            allowed.add(rec.Id);
        }
        return allowed;
    }

    // ─── Utilitaires ──────────────────────────────────────────────────────────

    private static Schema.SObjectType getSObjectType(String objectName) {
        if (!SOBJECT_CACHE.containsKey(objectName)) {
            SOBJECT_CACHE.put(objectName, Schema.getGlobalDescribe().get(objectName));
        }
        return SOBJECT_CACHE.get(objectName);
    }

    private static void assertConfig(RollupConfig c) {
        if (c == null)                           throw new RollupException('config est null');
        if (String.isBlank(c.childObject))       throw new RollupException('childObject est obligatoire');
        if (String.isBlank(c.relationshipField)) throw new RollupException('relationshipField est obligatoire');
        if (String.isBlank(c.aggregateFunction)) throw new RollupException('aggregateFunction est obligatoire');
        if (String.isBlank(c.parentObject))      throw new RollupException('parentObject est obligatoire');
        if (String.isBlank(c.targetField))       throw new RollupException('targetField est obligatoire');
        if (c.aggregateFunction != 'COUNT' && String.isBlank(c.fieldToAggregate)) {
            throw new RollupException('fieldToAggregate est obligatoire pour ' + c.aggregateFunction);
        }
        Set<String> valid = new Set<String>{ 'SUM', 'COUNT', 'MIN', 'MAX', 'AVG' };
        if (!valid.contains(c.aggregateFunction.toUpperCase())) {
            throw new RollupException('aggregateFunction invalide : ' + c.aggregateFunction);
        }
    }
}
