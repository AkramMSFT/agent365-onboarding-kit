package example;

import java.util.*;

public final class Main {
    public static void main(String[] arguments) {
        var args = new ArrayList<>(List.of(arguments));
        if (!args.isEmpty() && args.getFirst().equals("--help")) {
            System.out.println("mvn exec:java -Dexec.args=\"--mock text\" or \"--live prompt\"\nDefault: offline mock. Live mode reads MODEL_PROVIDER and its provider-specific environment key.");
            return;
        }
        String mode = !args.isEmpty() && args.getFirst().startsWith("--") ? args.removeFirst() : "--mock";
        if (!mode.equals("--mock") && !mode.equals("--live")) { System.err.println("Use --mock or --live."); System.exit(1); }
        String text = args.isEmpty() ? "Hello Agent 365" : String.join(" ", args);
        var offline = new Agent.OfflineModel(text);
        try (Agent.Model model = mode.equals("--live") ? new Agent.HttpModel(Agent.Provider.from(System.getenv())) : offline) {
            String output = Agent.run(model, text, 6);
            System.out.println(mode.equals("--live") ? output : Agent.JSON.toJson(Map.of(
                "mode", "mock", "aiInference", false, "output", output, "modelRequests", offline.requests)));
        } catch (Exception exception) {
            System.err.println("Agent failed: " + exception.getMessage());
            System.exit(1);
        }
    }
}
