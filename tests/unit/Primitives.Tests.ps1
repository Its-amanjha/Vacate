BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../src/Vacate/Vacate.psm1') -Force
}

Describe 'Test-VacateGlobMatch' {
    It 'matches * within one segment' {
        InModuleScope Vacate {
            Test-VacateGlobMatch -Pattern '*.json' -Name 'config.json' -CaseSensitive $true | Should -BeTrue
            Test-VacateGlobMatch -Pattern '*' -Name '' -CaseSensitive $true | Should -BeTrue
        }
    }
    It 'never matches across a separator' {
        InModuleScope Vacate {
            Test-VacateGlobMatch -Pattern '*' -Name 'a/b' -CaseSensitive $true | Should -BeFalse
            Test-VacateGlobMatch -Pattern '*' -Name 'a\b' -CaseSensitive $false | Should -BeFalse
            { Test-VacateGlobMatch -Pattern 'a/*' -Name 'a' -CaseSensitive $true } | Should -Throw
        }
    }
    It 'treats ? as exactly one char' {
        InModuleScope Vacate {
            Test-VacateGlobMatch -Pattern 'Profile ?' -Name 'Profile 1' -CaseSensitive $true | Should -BeTrue
            Test-VacateGlobMatch -Pattern 'Profile ?' -Name 'Profile 12' -CaseSensitive $true | Should -BeFalse
        }
    }
    It 'treats regex metacharacters literally (no injection)' {
        InModuleScope Vacate {
            Test-VacateGlobMatch -Pattern '.+' -Name 'abc' -CaseSensitive $true | Should -BeFalse
            Test-VacateGlobMatch -Pattern '.+' -Name '.+' -CaseSensitive $true | Should -BeTrue
            Test-VacateGlobMatch -Pattern '[ab]' -Name 'a' -CaseSensitive $true | Should -BeFalse
            Test-VacateGlobMatch -Pattern '(a|b)$' -Name '(a|b)$' -CaseSensitive $true | Should -BeTrue
        }
    }
    It 'respects case rules' {
        InModuleScope Vacate {
            Test-VacateGlobMatch -Pattern 'History' -Name 'history' -CaseSensitive $true | Should -BeFalse
            Test-VacateGlobMatch -Pattern 'History' -Name 'history' -CaseSensitive $false | Should -BeTrue
        }
    }
}

Describe 'Attribute helpers' {
    It 'detects reparse points' {
        InModuleScope Vacate {
            Test-VacateReparse -Attributes ([IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint) | Should -BeTrue
            Test-VacateReparse -Attributes ([IO.FileAttributes]::Directory) | Should -BeFalse
        }
    }
    It 'detects cloud placeholders' {
        InModuleScope Vacate {
            Test-VacateCloudPlaceholder -Attributes ([IO.FileAttributes]::Offline) | Should -BeTrue
            Test-VacateCloudPlaceholder -Attributes 0x400000 | Should -BeTrue
            Test-VacateCloudPlaceholder -Attributes (0x400000 -bor 0x20) | Should -BeTrue
            # Real FileSystemInfo.Attributes values bind too
            $item = Get-Item -LiteralPath ([IO.Path]::GetTempPath())
            { Test-VacateCloudPlaceholder -Attributes $item.Attributes } | Should -Not -Throw
            Test-VacateCloudPlaceholder -Attributes ([IO.FileAttributes]::Archive) | Should -BeFalse
        }
    }
}
