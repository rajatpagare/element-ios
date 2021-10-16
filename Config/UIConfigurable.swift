// 
// Copyright 2021 New Vector Ltd
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import Foundation
struct UIConfigurable {
	static private let infoDictionary = Bundle.main.infoDictionary!

	static var showRegisterButton: Bool {
		return boolean(forKey: "SHOW_REGISTER_BUTTON")
	}

	static func boolean(forKey key: String, inGroup group: String? = nil) -> Bool {
		var dict = infoDictionary
		if let group = group, let subDict = infoDictionary[group] as? [String: Any] {
			dict = subDict
		}
		guard let stringValue = dict[key] as? String else {
			return false
		}

		switch stringValue.lowercased() {
		case "true", "yes", "1":
			return true
		default:
			return false
		}
	}
}
