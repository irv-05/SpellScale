-- Minimal assertions for the test scripts.
local T = { failed = 0, passed = 0 }

local function report(pass, label, detail)
	if pass then
		T.passed = T.passed + 1
	else
		T.failed = T.failed + 1
		print("  FAIL " .. label .. (detail and ("  (" .. detail .. ")") or ""))
	end
end

function T.section(name)
	print("- " .. name)
end
function T.ok(cond, label)
	report(cond, label)
end
function T.eq(got, want, label)
	report(got == want, label, "got " .. tostring(got) .. ", want " .. tostring(want))
end
function T.near(got, want, tol, label)
	report(type(got) == "number" and math.abs(got - want) <= tol, label,
		"got " .. tostring(got) .. ", want " .. want .. " +/- " .. tol)
end
function T.done()
	print(string.format("%d passed, %d failed", T.passed, T.failed))
	os.exit(T.failed == 0 and 0 or 1)
end

return T
