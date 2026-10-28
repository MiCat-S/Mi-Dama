pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "Mi-Dama"

// core：纯 Kotlin（规则、布局分析、打码、撤销），不依赖 Android，在电脑上就能跑单测
// app：Android 界面、ML Kit 识别、相册读写
include(":core", ":app")
