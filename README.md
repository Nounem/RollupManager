# RollupManager

Moteur générique de calcul rollup entre deux objets Salesforce.  
Étend les Roll-Up Summary Fields (RUSF) natifs aux relations **Lookup** et à toute combinaison d'objets standard ou custom.

---

## Déploiement en un clic

> Remplacer `YOUR-USERNAME` par votre nom d'utilisateur GitHub après création du repo.

[![Deploy to Salesforce](https://githubsfdeploy.herokuapp.com/resources/img/deploy.png)](https://githubsfdeploy.herokuapp.com/?owner=YOUR-USERNAME&repo=RollupManager&ref=main)

---

## Fonctionnalités

- ✅ Support **Lookup** et **Master-Detail**
- ✅ Fonctions : **SUM, COUNT, MIN, MAX, AVG**
- ✅ Filtre sur les **enfants** (`filterCriteria`)
- ✅ Filtre sur les **parents** (`parentFilter`) — ex : uniquement les Accounts `Client`
- ✅ **Plusieurs rollups** sur le même objet enfant via `calculateAll()`
- ✅ Gestion de tous les événements DML : INSERT, UPDATE, DELETE, UNDELETE
- ✅ **Reparentage** automatique (recalcul ancien + nouveau parent)
- ✅ **Bulk-safe** — un seul DML quelque soit le volume
- ✅ **Anti-récursion** intégré par clé de config
- ✅ Optimisation UPDATE — recalcul uniquement si le champ pertinent a changé
- ✅ `Database.update(allOrNone: false)` — un parent en erreur ne bloque pas les autres
- ✅ 16 tests unitaires — couverture > 85 %

---

## Prérequis

- Salesforce CLI (`sf`)
- API version 67.0+
- Une org Salesforce (sandbox, scratch org ou production)

---

## Installation via Salesforce CLI

### 1. Cloner le repository

```bash
git clone https://github.com/YOUR-USERNAME/RollupManager.git
cd RollupManager
```

### 2. Authentifier votre org

```bash
sf org login web --alias mon-org
```

### 3. Déployer

```bash
sf project deploy start --source-dir force-app --target-org mon-org
```

### 4. Lancer les tests

```bash
sf apex run test --class-names RollupHelperTest --target-org mon-org --result-format human --wait 5
```

---

## Utilisation

### Principe

Un fichier à ne jamais modifier : `RollupHelper.cls`.  
Un trigger par objet enfant : copier le template, renseigner 8 variables, déployer.

```
Trigger (objet enfant)
    └── RollupHelper.calculateAll()
            ├── Collecte les IDs parent impactés
            ├── Filtre les parents éligibles (parentFilter)
            ├── Agrégation SOQL dynamique (filterCriteria)
            └── Database.update() → champ cible sur le parent
```

### Les 8 paramètres

```apex
RollupHelper.RollupConfig config = new RollupHelper.RollupConfig();

config.childObject        = 'Opportunity';  // API name objet enfant
config.relationshipField  = 'AccountId';    // champ de relation sur l'enfant
config.fieldToAggregate   = 'Amount';       // champ à agréger (null si COUNT)
config.aggregateFunction  = 'SUM';          // SUM | COUNT | MIN | MAX | AVG
config.parentObject       = 'Account';      // API name objet parent
config.targetField        = 'Total_CA__c';  // champ cible sur le parent
config.filterCriteria     = null;           // filtre sur les enfants (null = tous)
config.parentFilter       = null;           // filtre sur les parents (null = tous)
config.alwaysRecalculate  = false;          // true si filterCriteria porte sur un champ autre que fieldToAggregate
```

### Trigger template

```apex
trigger OpportunityRollupTrigger on Opportunity (
    after insert, after update, after delete, after undelete
) {
    List<RollupHelper.RollupConfig> configs = new List<RollupHelper.RollupConfig>();

    RollupHelper.RollupConfig config = new RollupHelper.RollupConfig();
    config.childObject       = 'Opportunity';
    config.relationshipField = 'AccountId';
    config.fieldToAggregate  = 'Amount';
    config.aggregateFunction = 'SUM';
    config.parentObject      = 'Account';
    config.targetField       = 'Total_CA__c';
    config.filterCriteria    = null;
    config.parentFilter      = null;
    config.alwaysRecalculate = false;
    configs.add(config);

    RollupHelper.calculateAll(
        configs,
        Trigger.new, Trigger.old,
        Trigger.isInsert, Trigger.isUpdate,
        Trigger.isDelete, Trigger.isUndelete
    );
}
```

---

## Exemples

### SUM des Opportunités gagnées → Account (type Client uniquement)

```apex
config.childObject       = 'Opportunity';
config.relationshipField = 'AccountId';
config.fieldToAggregate  = 'Amount';
config.aggregateFunction = 'SUM';
config.parentObject      = 'Account';
config.targetField       = 'Total_CA_Client__c';
config.filterCriteria    = 'StageName = \'Closed Won\'';
config.parentFilter      = 'RecordType.DeveloperName = \'Client\'';
config.alwaysRecalculate = true;
```

### COUNT des Cases ouverts → Account

```apex
config.childObject       = 'Case';
config.relationshipField = 'AccountId';
config.fieldToAggregate  = null;
config.aggregateFunction = 'COUNT';
config.parentObject      = 'Account';
config.targetField       = 'Nb_Cases_Ouverts__c';
config.filterCriteria    = 'Status != \'Closed\'';
config.parentFilter      = null;
config.alwaysRecalculate = true;
```

### SUM sur objets custom

```apex
config.childObject       = 'Ligne_Commande__c';
config.relationshipField = 'Commande__c';
config.fieldToAggregate  = 'Montant_HT__c';
config.aggregateFunction = 'SUM';
config.parentObject      = 'Commande__c';
config.targetField       = 'Total_HT__c';
config.filterCriteria    = 'Annule__c = false';
config.parentFilter      = null;
config.alwaysRecalculate = false;
```

### Plusieurs rollups sur le même objet (un seul trigger)

```apex
// Rollup 1
RollupHelper.RollupConfig c1 = new RollupHelper.RollupConfig();
c1.targetField = 'Total_CA__c'; c1.aggregateFunction = 'SUM'; ...
configs.add(c1);

// Rollup 2
RollupHelper.RollupConfig c2 = new RollupHelper.RollupConfig();
c2.targetField = 'Nb_Opportunites__c'; c2.aggregateFunction = 'COUNT'; ...
configs.add(c2);
```

---

## Structure du projet

```
force-app/main/default/
├── classes/
│   ├── RollupHelper.cls              ← moteur générique (ne pas modifier)
│   ├── RollupHelper.cls-meta.xml
│   ├── RollupHelperTest.cls          ← 16 tests unitaires
│   └── RollupHelperTest.cls-meta.xml
├── triggers/
│   ├── OpportunityRollupTrigger.trigger      ← exemple Account / Opportunity
│   └── OpportunityRollupTrigger.trigger-meta.xml
└── objects/
    └── Account/fields/
        └── Total_CA__c.field-meta.xml        ← exemple de champ cible
```

---

## Documentation complète

Voir [ROLLUP_GUIDE.md](ROLLUP_GUIDE.md) pour :

- Syntaxe complète de `filterCriteria` et `parentFilter`
- Les 3 scénarios multi-champs
- Les 8 cas gérés automatiquement
- Étapes de création d'un nouveau rollup
- Décisions de conception (`without sharing`, `allOrNone: false`, anti-récursion)

---

## Cas gérés

| Événement | Comportement |
|---|---|
| INSERT enfant | Recalcule le(s) parent(s) lié(s) |
| UPDATE `fieldToAggregate` | Recalcule si la valeur a changé |
| UPDATE relation (reparentage) | Recalcule l'ancien ET le nouveau parent |
| UPDATE sans changement pertinent | Retour immédiat, aucun SOQL ni DML |
| DELETE enfant | Recalcule le parent qui perd l'enregistrement |
| UNDELETE enfant | Recalcule le parent qui récupère l'enregistrement |
| BULK 200 enregistrements | Un seul DML groupé |
| Relation nulle | Ignoré silencieusement |
| Appel récursif | Bloqué par le guard anti-récursion |

---

## Licence

MIT
