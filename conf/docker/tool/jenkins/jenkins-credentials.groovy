if (!binding.hasVariable("encodedCredentialsYaml")) {
    throw new IllegalStateException("encodedCredentialsYaml must be provided by the external bootstrap script")
}

byte[] decryptedBytes = null
String yamlText = null
try {
    decryptedBytes = Base64.decoder.decode(encodedCredentialsYaml.toString())
    if (decryptedBytes.length == 0) {
        throw new IllegalStateException("CSP credentials are empty")
    }
    yamlText = new String(decryptedBytes, java.nio.charset.StandardCharsets.UTF_8)
} finally {
    if (decryptedBytes != null) {
        java.util.Arrays.fill(decryptedBytes, (byte) 0)
    }
}

def yamlRoot = new org.yaml.snakeyaml.Yaml().load(yamlText)
def adminCredentials = yamlRoot?.credentialholder?.admin

if (!(adminCredentials instanceof Map)) {
    throw new IllegalStateException("credentialholder.admin is required in credentials.yaml.enc")
}

def objectStorageKeys = [
    aws: ["aws_access_key_id", "aws_secret_access_key"],
    gcp: ["S3AccessKey", "S3SecretKey"],
    alibaba: ["AccessKeyId", "AccessKeySecret"],
    tencent: ["SecretId", "SecretKey"],
    ibm: ["S3AccessKey", "S3SecretKey"],
    ncp: ["ncloud_access_key", "ncloud_secret_key"],
    nhn: ["S3AccessKey", "S3SecretKey"]
]

def store = com.cloudbees.plugins.credentials.SystemCredentialsProvider.instance.store
def domain = com.cloudbees.plugins.credentials.domains.Domain.global()
def registered = []
def skipped = []

objectStorageKeys.each { provider, keys ->
    def providerCredentials = adminCredentials[provider]
    def accessKey = providerCredentials instanceof Map ? providerCredentials[keys[0]]?.toString()?.trim() : ""
    def secretKey = providerCredentials instanceof Map ? providerCredentials[keys[1]]?.toString()?.trim() : ""

    if (!accessKey || !secretKey) {
        skipped << provider
        return
    }
    if (accessKey.contains("\n") || accessKey.contains("\r") || secretKey.contains("\n") || secretKey.contains("\r")) {
        throw new IllegalStateException("Object Storage credential for ${provider} must not contain line breaks")
    }

    def credentialId = "object-storage-credential-${provider}"
    def credential = new com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl(
        com.cloudbees.plugins.credentials.CredentialsScope.GLOBAL,
        credentialId,
        "M-CMP Object Storage credential for ${provider.toUpperCase()}",
        accessKey,
        secretKey
    )
    def existing = store.getCredentials(domain).find { it.id == credentialId }
    def saved = existing ? store.updateCredentials(domain, existing, credential) : store.addCredentials(domain, credential)

    if (!saved) {
        throw new IllegalStateException("Failed to save Jenkins credential ${credentialId}")
    }
    registered << credentialId
}

registered.each { println "MCMP_OBJECT_STORAGE_CREDENTIAL_REGISTERED ${it}" }
skipped.each { println "MCMP_OBJECT_STORAGE_CREDENTIAL_SKIPPED ${it}" }
new File(jenkins.model.Jenkins.get().rootDir, ".mcmp-object-storage-credentials-initialized").text = "ready\n"
println "MCMP_OBJECT_STORAGE_CREDENTIALS_COMPLETE"

yamlText = null
yamlRoot = null
adminCredentials = null
