<div dir="rtl">

# דוח תקלות ותיקונים - EKS Production Stack

מסמך זה מרכז את כל הבעיות והשגיאות שהיו קיימות בפרויקט (הן ברמת הקוד ב-Terraform והן ברמת ההגדרות ב-Helm/Kubernetes), מסביר למה הן התרחשו במקור, וכיצד הן תוקנו כדי לייצר סביבה יציבה ועובדת מקצה לקצה.

---

## 1. שגיאת CrashLoopBackOff ו-CRDs חסרים ב-Vertical Pod Autoscaler (VPA)
* **תיאור הבעיה:** הפודים של ה-VPA (`vpa-recommender`, `vpa-updater`, ו-`vpa-admission-controller`) קרסו שוב ושוב ולא הצליחו לעלות.
* **סיבת התקלה:**
  1. קובץ ה-Helmfile ניסה להתקין את ה-Chart של ה-VPA ללא ה-Custom Resource Definitions (CRDs) הנדרשים (כגון `VerticalPodAutoscaler`), מה שמנע מהשירותים לתפקד.
  2. בקובץ `helm/values/vpa.yaml` היו פרמטרים כפולים תחת שדות ה-`args` של כל אחד מהפודים, שגרמו להתנגשות ולשגיאה בהפעלת ה-Container.
* **התיקון:**
  * נוסף `installCRDs: true` בהגדרות ה-Release של ה-VPA בקובץ `helmfile.yaml`.
  * נוקו השורות הכפולות והסותרות מתוך קובץ ה-Values של `vpa.yaml`.

**קוד להמחשה:**
<div dir="ltr">

```diff
# helmfile.yaml
  - name: vpa
    namespace: kube-system
    chart: cowboysysop/vertical-pod-autoscaler
+   installCRDs: true
    values:
    - ./values/vpa.yaml
```

</div>

<div dir="ltr">

```diff
# helm/values/vpa.yaml (Example Fix)
  recommender:
    extraArgs:
      v: "4"
-     prometheus-address: http://prometheus-operated.monitoring.svc
-     storage: prometheus
```

</div>

## 2. חוסר תאימות של גרסאות ה-API ב-Karpenter (API Version Mismatch)
* **תיאור הבעיה:** הקבצים של Karpenter שאחראים על הגדרת סוגי השרתים והקמתם נכשלו בשלב ה-`kubectl apply`.
* **סיבת התקלה:** הקבצים עשו שימוש ב-API ישן או לא נכון (`karpenter.sh/v1beta1`) שלא תאם לגרסת ה-Karpenter שרצה בקלאסטר.
* **התיקון:** עדכנו את `nodepool.yaml` לעבוד עם `karpenter.sh/v1` ואת `ec2nodeclass.yaml` לעבוד עם `karpenter.k8s.aws/v1`, בהתאם לדוקומנטציה המעודכנת של Karpenter.

**קוד להמחשה:**
<div dir="ltr">

```diff
# helm/manifests/nodepool.yaml
- apiVersion: karpenter.sh/v1beta1
+ apiVersion: karpenter.sh/v1
  kind: NodePool
  metadata:
    name: app-nodepool
```

</div>

<div dir="ltr">

```diff
# helm/manifests/ec2nodeclass.yaml
- apiVersion: karpenter.k8s.aws/v1beta1
+ apiVersion: karpenter.k8s.aws/v1
  kind: EC2NodeClass
```

</div>

## 3. שגיאת No Subnets Found ב-Karpenter (חוסר יכולת להקים שרתים)
* **תיאור הבעיה:** למרות ש-Karpenter היה פעיל, הוא לא הצליח להקים שרתים (Nodes) והחזיר שגיאות שהוא לא מוצא רשתות (Subnets) להקים בהם את השרתים.
* **סיבת התקלה:** ב-Terraform, המודול שיצר את הרשתות (`modules/vpc/main.tf`) תייג את ה-Subnets עם התגית `karpenter.sh/discovery = eks-production-stack-cluster` (כי הוא השתמש במשתנה `${var.project_name}`). אבל, ה-Cluster בפועל נקרא `eks-production-cluster`. כתוצאה מכך Karpenter לא מצא את הרשתות שלו כי הוא חיפש תגית אחרת.
* **התיקון:** שינוי התגית ב-`main.tf` כך שתהיה מקודדת מראש לשם הנכון (`eks-production-cluster`) והרצת `terraform apply`.

**קוד להמחשה:**
<div dir="ltr">

```diff
# terraform/modules/vpc/main.tf
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
-   "karpenter.sh/discovery"          = "${var.project_name}-cluster"
+   "karpenter.sh/discovery"          = "eks-production-cluster"
  }
```

</div>

## 4. שגיאת AccessDenied ל-Karpenter בגישה ל-AWS
* **תיאור הבעיה:** ברגע ש-Karpenter כבר מצא את הרשתות, הוא נתקל בשגיאת הרשאות (Access Denied) כשהוא ניסה להקים מכונות EC2.
* **סיבת התקלה:** הקובץ `ec2nodeclass.yaml` הכיל בשדה ה-`role` ערך ישן של IAM Role שנוצר בריצות קודמות (לפני `terraform destroy`). בכל פעם ש-Terraform הורץ מחדש, הוא ייצר Role חדש, אבל הקובץ הסטטי לא התעדכן.
* **התיקון האוטומטי:** הוספתי פקודת `sed` לתוך הסקריפט `scripts/generate-values.sh` שבאופן אוטומטי לוקחת את ה-Role ARN החדש ש-Terraform פולט בשלב ה-Outputs, ומזריקה אותו לתוך `ec2nodeclass.yaml`. כך הבעיה לא תחזור על עצמה במחיקה והקמה מחדש.

**קוד להמחשה:**
<div dir="ltr">

```bash
# Error logged by Karpenter
# AccessDenied: User is not authorized to perform: iam:PassRole on resource

# Fix: Added to scripts/generate-values.sh to dynamically inject the correct IAM Role
sed -i "s/role: Karpenter-.*/role: ${KARPENTER_NODE_ROLE}/" "$EC2NODECLASS_FILE"
```

</div>

## 5. הפודים של External Secrets היו תקועים ב-Pending
* **תיאור הבעיה:** הפודים שאחראים על התחברות ל-AWS Secrets Manager לא הצליחו למצוא שרת להריץ עליו את עצמם.
* **סיבת התקלה:** השרתים היחידים שהיו זמינים בקלאסטר (ה-Fargate או ה-Managed Node Groups המקוריים) הכילו Taint של `CriticalAddonsOnly`, כלומר הם מקבלים רק פודים של מערכת. מכיוון ש-Karpenter סבל משגיאות 3 ו-4 הוא לא הקים שרתים חלופיים.
* **התיקון:** ברגע שבעיות 3 ו-4 תוקנו, Karpenter הקים מיידית שרת עבור קבוצת ה-`app-nodepool` והפודים של External Secrets הצליחו לרוץ.

**קוד להמחשה:**
<div dir="ltr">

```bash
# Output from 'kubectl describe pod' when it was failing:
# Warning  FailedScheduling  default-scheduler  0/2 nodes are available: 2 node(s) had untolerated taint {CriticalAddonsOnly: true}.
```

</div>

## 6. שגיאת InvalidProviderConfig ב-External Secrets (לא מצליח למשוך סודות)
* **תיאור הבעיה:** הפוד של ה-Backend שלנו קרס עם שגיאת `CreateContainerConfigError` משום שהוא לא מצא את ה-Secret בשם `db-credentials`. הסיבה הייתה שה-`ClusterSecretStore` היה במצב שגיאה ולא הצליח להתחבר ל-AWS.
* **סיבת התקלה:** קובץ ההגדרות `helm/values/external-secrets.yaml` דרש ציון של ה-IRSA Role (IAM Role for Service Accounts) כדי לאמת מול AWS, אבל השדה שם נשאר ריק: `eks.amazonaws.com/role-arn: ""`.
* **התיקון האוטומטי:** בדיוק כמו בבעיה 4, הוספתי פקודת החלפה (`sed`) לסקריפט `scripts/generate-values.sh` שמזריקה פנימה באופן אוטומטי את ה-Role ARN החדש שנוצר ב-Terraform בכל הרצה מחדש.

**קוד להמחשה:**
<div dir="ltr">

```diff
# Error logged by ClusterSecretStore
# Warning  InvalidProviderConfig  cluster-secret-store  unable to create session: an IAM role must be associated

# Fix: Added to scripts/generate-values.sh
+ sed -i "s|eks.amazonaws.com/role-arn: .*|eks.amazonaws.com/role-arn: "${EXTERNAL_SECRETS_ROLE_ARN}"|" "$EXT_SECRETS_FILE"
```

</div>

## 7. פוד מסד הנתונים תקוע ב-Pending עקב StorageClass חסר
* **תיאור הבעיה:** הפוד `database-postgresql-0` לא הצליח לקבל שרת, והשגיאה שהוצגה הייתה שה-`PersistentVolumeClaim` (הדיסק שלו) לא יכול להיווצר כי אין `StorageClass` בשם `gp3` מוגדר בקלאסטר. 
* **סיבת התקלה:** התקנת ה-Helm של הדאטה-בייס ציפתה לכונן מסוג AWS gp3, אבל קוברנטיס לא מגיע עם gp3 כברירת מחדל אלא אם כן מגדירים לו את ה-StorageClass במפורש.
* **התיקון:** 
  1. יצרתי קובץ בשם `helm/manifests/gp3-storageclass.yaml` המגדיר את ה-`gp3`.
  2. הוספתי פקודת `kubectl apply` לסקריפט ההפעלה `scripts/deploy.sh` כך שהוא יווצר לפני ההקמה של ה-Database, ורק לאחר מכן Karpenter יקים עבור הדאטה-בייס את שרת ה-`db-nodepool`.

**קוד להמחשה:**
<div dir="ltr">

```yaml
# helm/manifests/gp3-storageclass.yaml (New File)
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
parameters:
  type: gp3
  fsType: ext4
```

</div>

## 8. שגיאות בהתקנת Prometheus (kube-prometheus-stack)
* **תיאור הבעיה:** בשלבים הראשונים, `helmfile sync` קרס בניסיון להתקין את חבילת הניטור של Prometheus ו-Grafana.
* **סיבת התקלה:** קובץ ה-Values המקוסטם של מוניטורינג (`monitoring.yaml`) הכיל שגיאות תחביר, לייבלים (labels) חסרים או לא תואמים בבלוקים של ה-`serviceMonitors`, והגדרות חסרות סביב תאימות גרסאות.
* **התיקון:** שיכתוב ותיקון שגיאות התחביר בקובץ ה-YAML של מוניטורינג, כדי לאפשר ל-Helm לסיים את התקנת הכלים בצורה חלקה בתוך הנאמפייס (Namespace) הנכון.

**קוד להמחשה:**
<div dir="ltr">

```diff
# helm/values/monitoring.yaml
  additionalServiceMonitors:
    - name: frontend-monitor
+     selector:
+       matchLabels:
+         app.kubernetes.io/name: frontend
      endpoints:
        - port: http
```

</div>

## 9. שגיאת מחיקה נתקעת (Webhook Timeout) בסקריפט destroy.sh
* **תיאור הבעיה:** כשניסית להריץ את סקריפט המחיקה (`destroy.sh`), המערכת נתקעה והחזירה שגיאת Webhook Timeout בזמן שניסתה למחוק את `external-secret.yaml`.
* **סיבת התקלה:** סקריפט המחיקה מחק קודם את שרתי ה-Karpenter (מה שהוביל לכיבוי השרת שעליו רץ ה-Webhook של External Secrets). לאחר מכן, קוברנטיס ניסה לפנות ל-Webhook כדי לאשר את מחיקת ה-Secret, אבל מכיוון שה-Webhook כבר נמחק פיזית, הפעולה נתקעה לנצח (Chicken and Egg).
* **התיקון:** שיניתי את סדר הפקודות בתוך הסקריפט `destroy.sh`, כך שהוא קודם כל מוחק את ה-Secrets (בזמן שהשרתים וה-Webhook עדיין באוויר), ורק לאחר מכן מוחק את השרתים וה-NodePools של Karpenter.

**קוד להמחשה:**
<div dir="ltr">

```diff
# scripts/destroy.sh
- kubectl delete -f "$HELM_DIR/manifests/nodepool.yaml"
- kubectl delete -f "$HELM_DIR/manifests/ec2nodeclass.yaml"
- kubectl delete -f "$HELM_DIR/manifests/external-secret.yaml"
- kubectl delete -f "$HELM_DIR/manifests/cluster-secret-store.yaml"

# Fix: Delete secrets BEFORE Karpenter nodes are terminated
+ kubectl delete -f "$HELM_DIR/manifests/external-secret.yaml"
+ kubectl delete -f "$HELM_DIR/manifests/cluster-secret-store.yaml"
+ kubectl delete -f "$HELM_DIR/manifests/nodepool.yaml"
+ kubectl delete -f "$HELM_DIR/manifests/ec2nodeclass.yaml"
```

</div>

---

### סיכום תהליך ה-Deploy האוטומטי
בעזרת העדכונים הנ"ל לסקריפטים `deploy.sh` ו-`generate-values.sh`, תהליך המחיקה וההקמה מחדש כבר לא דורש שום התערבות ידנית. כל התלויות (IAM Roles, דיסקים, תגיות VPC ו-CRDs) מסונכרנות באופן שקוף לחלוטין.


## 10. שגיאת ImagePullBackOff בגיבוי (בלבול בין גרסת Chart לגרסת Image)
* **תיאור הבעיה:** משימת הגיבוי המתוזמנת (CronJob) נכשלה עם שגיאת `ImagePullBackOff` ולא הצליחה למשוך את תמונת ה-Docker. בנוסף, בשלבים שונים הפוד נתקע במצב `Pending` כי לא יכל לרוץ על שרתי ה-Database.
* **סיבת התקלה:**
  1. הוגדרה תגית התמונה ב-CronJob בתור `18.7.0` או שהיא נוסתה תחת השם `bitnamicharts/postgresql`. זוהי שגיאה נפוצה – `18.7.0` היא גרסת ה-**Helm Chart**, ולא גרסת ה-**Docker Image** (שהייתה `18.4.0` ודרשה שם ארוך הכולל את מערכת ההפעלה, למשל `18.4.0-debian-12`). כתוצאה מכך ה-Registry החזיר "Not Found".
  2. במקביל, חסרה הייתה הגדרת חריגה (`Tolerations`) שתאפשר לגיבוי לרוץ על השרתים הייעודיים של ה-Database (שסומנו ב-`Taint` למניעת הרצת פודים אחרים).
  3. משיכת התמונות מ-Docker Hub לעיתים הגיעה למגבלת קצב (Rate Limit) בגלל השימוש ב-AWS NAT Gateway, מה שהצריך מעבר למקור אמין ופתוח יותר.
* **התיקון:**
  * שינוי ה-Registry למשיכה ממאגר ה-ECR הפומבי של AWS (שהוא נטול מגבלות הורדה מתוך רשת אמזון): `public.ecr.aws/bitnami/postgresql`.
  * שימוש בגרסה המדויקת והדינמית של מסד הנתונים בעזרת ההגדרות מה-Helm: `{{ .Values.postgresql.image.tag }}`.
  * הוספת בלוק `tolerations` ו-`nodeAffinity` ל-CronJob.

**קוד להמחשה:**
<div dir="ltr">

```diff
# helm/charts/database/templates/postgres-backup-cronjob.yaml
          containers:
            - name: backup
-             image: bitnami/postgresql:18.7.0
+             image: public.ecr.aws/bitnami/postgresql:{{ .Values.postgresql.image.tag | default "18.4.0" }}

        spec:
          serviceAccountName: backup-sa
+         tolerations:
+           - key: "workload"
+             operator: "Equal"
+             value: "database"
+             effect: "NoSchedule"
+         affinity:
+           nodeAffinity:
+             requiredDuringSchedulingIgnoredDuringExecution:
+               nodeSelectorTerms:
+                 - matchExpressions:
+                     - key: "role"
+                       operator: "In"
+                       values:
+                         - "db"
```

</div>


## 11. פתרון תקלות מתקדם בגיבוי מסד הנתונים (Section 7 Backup)
*חלק זה מבוסס על תהליך דיבוג עצמאי מעמיק שכלל מספר שגיאות רצופות.*

**1. שגיאת משיכת תמונה (ErrImagePull - bitnami/postgresql:18.4.0)**
* **בעיה:** חברת Bitnami הפסיקו לפרסם תגיות ספציפיות ויציבות ב-Docker Hub.
* **פתרון:** שימוש ב-ECR Public Registry הפתוח והמהיר של אמזון: `public.ecr.aws/bitnami/postgresql:18.4.0`.

**2. נתיב awscli לא נכון (No such file or directory)**
* **בעיה:** פקודת ההעתקה `cp -r` בקונטיינר ההתחלתי (initContainer) העתיקה את ה-symlink שנקרא `current` כקובץ טקסט ולא כ-link אמיתי לקבצי ההרצה.
* **פתרון:** יצירת symlink חדש ודינמי מתוך ה-initContainer שמצביע לתיקייה הנכונה:
<div dir="ltr">

```bash
ln -sfn /tools/aws-cli/v2/$(ls /tools/aws-cli/v2/ | grep -v current) /tools/aws-cli/v2/current
```

</div>

**3. התנגשות Entrypoint של amazon/aws-cli**
* **בעיה:** תמונת ה-Docker של אמזון מריצה את הפקודה `aws` כ-Entrypoint ברירת מחדל, ולכן פקודת ה-`cp` התפרשה בטעות כחלק מפקודת `aws cp`.
* **פתרון:** דריסת ה-Entrypoint ההתחלתי באמצעות הגדרת `command: ["/bin/sh", "-c"]`.

**4. כישלון אימות סיסמה (Password authentication failed)**
* **בעיה:** מסד הנתונים הוקם עם הסיסמה `secret_password` שנשמרה פיזית ב-PVC, בעוד שה-CronJob וה-ExternalSecrets השתמשו בסיסמה האקראית המאובטחת `123456`.
* **פתרון:** מחיקת ה-PVC הישן ומחיקת הפוד, מה שגרם ל-DB לאתחל את עצמו מחדש עם הסיסמה הנכונה מהסיקרט החדש.

**5. שימוש ב-existingSecret לא עבד כברירת מחדל**
* **בעיה:** ה-Chart של Bitnami לא ידע איזה Key לקחת מתוך ה-`db-credentials` (כיוון שהיו לו שמות מותאמים אישית).
* **פתרון:** הוספת מיפוי Keys מפורש תחת בלוק ה-auth ב-Values:
<div dir="ltr">

```yaml
postgresql:
  auth:
    existingSecret: "db-credentials"
    secretKeys:
      adminPasswordKey: password
      userPasswordKey: password
```

</div>

**6. שגיאת הרשאות בגישה לתיקיית aws. (Permission denied: /.aws)**
* **בעיה:** כלי ה-awscli ניסה לכתוב קבצי תצורה לתיקיית `/`, אבל הקונטיינר של ביטנמי רץ מטעמי אבטחה כמשתמש מוגבל (user 1001).
* **פתרון:** הוספת משתנה סביבה שמפנה את ספריית הבית לתיקייה זמנית מורשית:
<div dir="ltr">

```yaml
- name: HOME
  value: /tmp
```

</div>

**7. שגיאת Timeout בעדכון VPA**
* **בעיה:** פקודת `helmfile sync` נתקעה וזרקה `cannot patch VerticalPodAutoscaler: Timeout`.
* **פתרון:** מחיקה ידנית של אובייקט ה-VPA התקוע כדי לאפשר ל-Helm ליצור אותו מחדש.
<div dir="ltr">

```bash
kubectl delete vpa database-database-vpa -n production
```

</div>


</div>