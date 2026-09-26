import ExtensionFoundation

extension AppExtensionPoint {
    @Definition
    static var syntheticVaultUI: AppExtensionPoint {
        Name("syntheticVaultUI")
        UserInterface(true)
    }
}
